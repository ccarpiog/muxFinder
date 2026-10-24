import Foundation

/// Hiding the launch tab once attached (PLAN.md D29): the bury after a confirmed and activated
/// attach, the race with the helper's restore closed by order, the watch over the tabs the
/// coordinator buried while the app runs (memory only), and the serialization of a bury and
/// "Show tab" on one tab.
///
/// Decisions read `ListSessions`' `buried_sessions`, never the `buried` property. Every
/// request is sent once (D13); a failure ends that step and is recorded in diagnostics without
/// ids, names or terminal content.
extension AttachCoordinator {
  /// How many buried launch tabs the coordinator watches, like `rememberedLaunches`. A tab it
  /// forgot is left to its helper, which restores it itself on every end the spike tried.
  static let rememberedBuriedTabs = 64

  /// One launch tab this coordinator buried (or may have buried, `LaunchTabBurial.uncertain`),
  /// watched until its helper ended.
  struct BuriedTab: Sendable {
    /// The launch running in it: the name of its helper's result file.
    let launchID: LaunchToken
    /// The launch tab's iTerm2 session (the tmux gateway).
    let gatewaySessionID: String
    /// Its tmux connection.
    let connectionID: String
    /// The helper's result, once seen (peeked, or taken by a detach, also during the bury).
    var result: LaunchResult?
    /// When the result was first seen.
    var resultSeenAt: ContinuousClock.Instant?
    /// Whether a connection listing showed the tab no longer owning its connection while no
    /// result was there (the check right after the bury, whose restore then failed, or an
    /// attachment check that started while the tab was watched): tmux ended and the result is
    /// late, or the sweep removed it, or the helper died without one.
    var ownsNoConnection = false
  }

  /// The helper's result a detach handed over (`noteHelperResult(_:)`) while the bury of its
  /// launch tab, or the check after it, still awaited iTerm2: no peek can see it any more.
  struct HandedOverResult: Sendable {
    /// The result, once handed over.
    var result: LaunchResult?
    /// When it was handed over.
    var seenAt: ContinuousClock.Instant?
  }

  /// A bury or "Show tab" running for one launch tab.
  struct TabOperation: Sendable {
    /// Tells it apart from later ones on the same tab.
    let id: UInt64
    /// Ends when it ended.
    let done: Task<Void, Never>
  }

  // MARK: - The bury

  /// Step 10: buries the launch tab `gatewaySessionID` of a confirmed attach, only when step 9
  /// activated a tab of its connection (S6: a tmux window shows, so hiding the gateway leaves
  /// the session on screen), and returns the outcome. `noTab` and a failed activation are
  /// skipped with nothing sent. The bury and the check after it run in a task of their own,
  /// after any "Show tab" of the same tab (`onLaunchTab(_:_:)`), so cancelling the attach
  /// cannot cut them short. Coalesced callers share the launch, so this runs once per launch.
  func buryLaunchTab(
    after activation: ActivationOutcome,
    gatewaySessionID: String,
    connectionID: String,
    launchID: LaunchToken
  ) async -> LaunchTabBurial {
    guard configuration.buriesLaunchTabs else { return .skipped(.turnedOff) }
    switch activation {
    case .activated: break
    case .noTab: return .skipped(.noTab)
    case .failed: return .skipped(.activationFailed)
    }
    return await onLaunchTab(gatewaySessionID) { coordinator in
      await coordinator.performBury(
        gatewaySessionID: gatewaySessionID, connectionID: connectionID, launchID: launchID)
    }
  } // End of func buryLaunchTab(after:gatewaySessionID:connectionID:launchID:)

  /// The bury, bound to the launch tab's connection
  /// (`ITerm2Integration.buryLaunchTab(sessionID:ifOwnsTmuxConnection:)`), then the race
  /// closed by order (PLAN.md D29): the helper writes its result before its first restore, so
  /// once the bury was answered (or went unanswered), the result (a peek, never a take:
  /// `detach` still takes it; or the one a detach took meanwhile and handed over,
  /// `buriesInFlight`) and the connection's owner tell whether tmux ended. If it did, the bury
  /// may have come after the helper's restore, so the tab is restored at once
  /// (`restoredAfterEnd`). Otherwise, or when that restore failed, a tab that may be buried is
  /// remembered for the watch with what the check learned: the result, or that the tab no
  /// longer owns its connection, so the recovery acts on it as soon as it is due.
  func performBury(
    gatewaySessionID: String,
    connectionID: String,
    launchID: LaunchToken
  ) async -> LaunchTabBurial {
    // From here until the tab is remembered (or not), a result a detach takes is kept here.
    buriesInFlight[launchID] = HandedOverResult()
    defer { buriesInFlight[launchID] = nil }
    var burial = LaunchTabBurial.buried
    do {
      try await iTerm2.buryLaunchTab(
        sessionID: gatewaySessionID, ifOwnsTmuxConnection: connectionID)
    } catch let error as ITerm2Error {
      if Self.buryCertainlyFailed(error) { return .failed(error) }
      burial = .uncertain
    } catch {
      burial = .uncertain
    }
    let peeked = try? store.peekResult(launchID)
    let peekedAt = clock.now()
    var ownsNoConnection = false
    if peeked == nil, buriesInFlight[launchID]?.result == nil,
      let connections = try? await iTerm2.listTmuxConnections()
    {
      ownsNoConnection = !connections.contains {
        $0.connectionID == connectionID && $0.owningSessionID == gatewaySessionID
      }
    }
    let ended = peeked != nil || ownsNoConnection || buriesInFlight[launchID]?.result != nil
    if ended, (try? await iTerm2.setBuried(false, sessionID: gatewaySessionID)) != nil {
      return .restoredAfterEnd
    }
    // A restore that failed leaves the tab to the watch, which restores it again once it is
    // due: at once after a helper failure or a connection loss, after the close delay after a
    // clean end, or once a result shows when none was seen yet.
    let handedOver = buriesInFlight[launchID]
    rememberBuriedTab(
      BuriedTab(
        launchID: launchID, gatewaySessionID: gatewaySessionID, connectionID: connectionID,
        result: peeked ?? handedOver?.result,
        resultSeenAt: peeked == nil ? handedOver?.seenAt : peekedAt,
        ownsNoConnection: ownsNoConnection))
    startBuriedTabRecoveryIfDue()
    return burial
  } // End of func performBury(gatewaySessionID:connectionID:launchID:)

  /// Whether a failed bury certainly buried nothing: it was not sent (`ITerm2Error.isNotSent`,
  /// which covers `tmuxConnectionNotOwned`), or iTerm2 answered it with an error
  /// (`setPropertyFailed`, `requestFailed`). Any other failure is an unknown outcome.
  static func buryCertainlyFailed(_ error: ITerm2Error) -> Bool {
    if error.isNotSent { return true }
    switch error {
    case .setPropertyFailed, .requestFailed: return true
    default: return false
    }
  }

  /// Runs `operation` for the launch tab `sessionID` in a task of its own, once every earlier
  /// bury or "Show tab" of that tab ended, and returns its value: a bury and a show never
  /// overlap on one tab, and cancelling the caller never cuts one short.
  func onLaunchTab<Value: Sendable>(
    _ sessionID: String,
    _ operation: @escaping @Sendable (isolated AttachCoordinator) async -> Value
  ) async -> Value {
    let previous = tabOperations[sessionID]?.done
    lastTabOperationID += 1
    let id = lastTabOperationID
    let work = Task { () -> Value in
      await previous?.value
      return await operation(self)
    }
    tabOperations[sessionID] = TabOperation(id: id, done: Task { _ = await work.value })
    let value = await work.value
    if tabOperations[sessionID]?.id == id { tabOperations[sessionID] = nil }
    return value
  } // End of func onLaunchTab(_:_:)

  // MARK: - Remembered buried tabs

  /// Remembers `tab` (replacing an older entry of the same launch tab), forgets the oldest one
  /// beyond `rememberedBuriedTabs`, and starts the timer.
  func rememberBuriedTab(_ tab: BuriedTab) {
    buriedTabs.removeAll { $0.gatewaySessionID == tab.gatewaySessionID }
    buriedTabs.append(tab)
    if buriedTabs.count > Self.rememberedBuriedTabs {
      buriedTabs.removeFirst(buriedTabs.count - Self.rememberedBuriedTabs)
    }
    startBuriedTabTimer()
  }

  /// Forgets the launch tab `gatewaySessionID` (restored by "Show tab": no longer buried).
  func forgetBuriedTab(gatewaySessionID: String) {
    buriedTabs.removeAll { $0.gatewaySessionID == gatewaySessionID }
  }

  /// The session ids of the buried tabs the coordinator watches, oldest first. For tests.
  var watchedBuriedTabs: [String] { buriedTabs.map(\.gatewaySessionID) }

  /// The file-only look (PLAN.md D29): peeks at the helper's result of every watched tab that
  /// has none yet, then starts the recovery when a tab needs iTerm2. Every attach, detach and
  /// attachment check runs it, and so does the timer. Nothing here contacts iTerm2.
  func checkBuriedTabs() {
    guard !buriedTabs.isEmpty else { return }
    buriedTabChecks += 1
    let now = clock.now()
    for index in buriedTabs.indices where buriedTabs[index].result == nil {
      guard let result = try? store.peekResult(buriedTabs[index].launchID) else { continue }
      buriedTabs[index].result = result
      buriedTabs[index].resultSeenAt = now
    }
    startBuriedTabRecoveryIfDue()
  } // End of func checkBuriedTabs()

  /// Runs `checkBuriedTabs()` now and waits until the recovery it started (or one running)
  /// ended. For tests and callers that want the outcome.
  func checkBuriedLaunchTabs() async {
    checkBuriedTabs()
    await buriedTabRecovery?.value
  }

  /// Hands the watch a helper result a detach took for one of its tabs, which no peek would
  /// see any more; while that tab's bury or the check after it still awaits iTerm2, the result
  /// is kept for that check (`buriesInFlight`), which remembers it with the tab.
  func noteHelperResult(_ result: LaunchResult) {
    if let inFlight = buriesInFlight[result.id] {
      guard inFlight.result == nil else { return }
      buriesInFlight[result.id] = HandedOverResult(result: result, seenAt: clock.now())
      return
    }
    guard let index = buriedTabs.firstIndex(where: { $0.launchID == result.id }),
      buriedTabs[index].result == nil
    else { return }
    buriedTabs[index].result = result
    buriedTabs[index].resultSeenAt = clock.now()
    startBuriedTabRecoveryIfDue()
  } // End of func noteHelperResult(_:)

  /// The launches of the watched tabs, taken before an attachment check starts its listing
  /// (`noteConnectionOwners(in:watchedBefore:)`).
  func watchedLaunchIDs() -> Set<LaunchToken> {
    Set(buriedTabs.map(\.launchID))
  }

  /// The attachment check's look: an attachment snapshot lists every tmux connection with its
  /// owner (when its filter left none out), so a watched tab without a result that owns no
  /// listed connection has ended without a result the coordinator could see (a result the
  /// sweep removed after D14's 120 s, or a helper that died without one). Such a tab is
  /// restored and left visible. The peek runs first, so a result written meanwhile wins.
  ///
  /// Only the tabs in `watchedBefore` (watched before the check started, so buried before its
  /// listing) are judged: a snapshot lists the connections before it awaits their identity
  /// answers, so a tab buried meanwhile, by an attach running alongside, cannot be in it.
  func noteConnectionOwners(
    in snapshot: AttachmentSnapshot,
    watchedBefore watched: Set<LaunchToken>
  ) {
    guard !buriedTabs.isEmpty, !watched.isEmpty, snapshot.excludedCount == 0 else { return }
    var owned = Set(snapshot.attachments.map { "\($0.connectionID)\u{0}\($0.owningSessionID)" })
    for entry in snapshot.unmapped {
      guard let connectionID = entry.connectionID, let owner = entry.owningSessionID else {
        continue
      }
      owned.insert("\(connectionID)\u{0}\(owner)")
    }
    for index in buriedTabs.indices where buriedTabs[index].result == nil {
      let tab = buriedTabs[index]
      guard watched.contains(tab.launchID) else { continue }
      if !owned.contains("\(tab.connectionID)\u{0}\(tab.gatewaySessionID)") {
        buriedTabs[index].ownsNoConnection = true
      }
    } // End of loop over the watched tabs
    checkBuriedTabs()
  } // End of func noteConnectionOwners(in:watchedBefore:)

  // MARK: - Timer

  /// Starts the timer unless it runs, is off, or nothing is watched. It ticks every
  /// `buriedTabCheckInterval` on its own clock and ends on the first tick that finds nothing
  /// watched (or once the coordinator is gone).
  func startBuriedTabTimer() {
    guard buriedTabTimerTask == nil, !buriedTabs.isEmpty, let timerClock = buriedTabTimerClock
    else { return }
    let interval = configuration.buriedTabCheckInterval
    buriedTabTimerTask = Task { [weak self] in
      while true {
        do {
          try await timerClock.sleep(for: interval)
        } catch {
          return
        }
        guard let coordinator = self else { return }
        guard await coordinator.buriedTabTimerTick() else { return }
      } // End of loop over the timer's ticks
    }
  } // End of func startBuriedTabTimer()

  /// One tick: the file-only look. Returns whether the timer goes on (a tab is still watched);
  /// when not, the timer is cleared here, so the next bury starts a new one.
  func buriedTabTimerTick() -> Bool {
    checkBuriedTabs()
    guard buriedTabs.isEmpty else { return true }
    buriedTabTimerTask = nil
    return false
  }

  // MARK: - Recovery

  /// Whether `tab` needs iTerm2 now: its helper reported a failure (restored at once, so its
  /// explanation shows), it owns no connection and has no result, or it ended cleanly at least
  /// `buriedTabCloseDelay` ago (the helper has surely exited, so a tab still listed is dead).
  func needsRecovery(_ tab: BuriedTab, at now: ContinuousClock.Instant) -> Bool {
    if let result = tab.result {
      guard result.succeeded else { return true }
      guard let seen = tab.resultSeenAt else { return true }
      return now >= seen + configuration.buriedTabCloseDelay
    }
    return tab.ownsNoConnection
  }

  /// Starts the recovery unless one runs or no watched tab needs iTerm2.
  func startBuriedTabRecoveryIfDue() {
    let now = clock.now()
    guard buriedTabRecovery == nil, buriedTabs.contains(where: { needsRecovery($0, at: now) })
    else { return }
    buriedTabRecovery = Task { await self.recoverBuriedTabs() }
  }

  /// The recovery: while watched tabs need iTerm2, lists the sessions once for them and
  /// handles each (`recover(_:in:)`), which forgets it; one attempt per tab (D13).
  func recoverBuriedTabs() async {
    while true {
      let now = clock.now()
      let due = buriedTabs.filter { needsRecovery($0, at: now) }
      guard !due.isEmpty else { break }
      for tab in due {
        buriedTabs.removeAll { $0.launchID == tab.launchID }
      }
      let listing = try? await iTerm2.listSessions()
      for tab in due { await recover(tab, in: listing) }
    } // End of loop over the rounds of due tabs
    buriedTabRecovery = nil
  } // End of func recoverBuriedTabs()

  /// Recovers one buried tab whose helper ended, from `listing` (`nil` when it failed; then
  /// nothing is sent): a tab in `buried_sessions` is restored (`setBuried(false)`). After a
  /// helper failure, or without a result, the tab is left visible, so its explanation (or
  /// whatever it shows) can be read. After a clean end, a tab still listed (buried or in a
  /// tab) is dead (S4: the helper's restores never reached iTerm2) and is closed, forced, by
  /// its own session id (`closeDeadTab(_:)`); one not listed closed by itself.
  func recover(_ tab: BuriedTab, in listing: ITerm2API.ListSessionsResponse?) async {
    let start = clock.now()
    let ending =
      tab.result.map { $0.succeeded ? "ended cleanly" : "helper failed" } ?? "no helper result"
    guard let listing else {
      await recordRecovery("\(ending); the sessions could not be listed", failed: true, start)
      return
    }
    let gateway = tab.gatewaySessionID
    guard listing.allSessionIDs.contains(gateway) else {
      await recordRecovery("\(ending); it closed by itself", failed: false, start)
      return
    }
    var restore = "in a tab"
    if listing.buriedSessions.contains(where: { $0.uniqueIdentifier == gateway }) {
      do {
        try await iTerm2.setBuried(false, sessionID: gateway)
        restore = "restored"
      } catch let error as ITerm2Error {
        restore = "restore failed (\(error.kind))"
      } catch {
        restore = "restore failed"
      }
    }
    guard tab.result?.succeeded == true else {
      await recordRecovery("\(ending); \(restore), left visible", failed: false, start)
      return
    }
    let closed = await closeDeadTab(gateway)
    await recordRecovery(
      "\(ending) but still listed; \(restore); \(closed.detail)", failed: !closed.gone, start)
  } // End of func recover(_:in:)

  /// Closes the dead launch tab `gatewaySessionID` (forced `Close` by its own session id, once)
  /// and waits within `buriedTabCloseBudget` for it to leave the listing. Returns whether it is
  /// gone, and what the status and the listing said.
  func closeDeadTab(_ gatewaySessionID: String) async -> (gone: Bool, detail: String) {
    let detail: String
    do {
      let response = try await iTerm2.close(
        ITerm2API.CloseRequest(target: .sessions([gatewaySessionID]), force: true))
      detail =
        response.statuses == [.ok]
        ? "Close answered OK" : "Close answered \(response.statuses.count) unexpected status(es)"
    } catch let error as ITerm2Error {
      detail = "Close failed (\(error.kind))"
    } catch {
      detail = "Close failed"
    }
    let deadline = clock.now() + configuration.buriedTabCloseBudget
    var gone = false
    while true {
      guard let sessions = try? await iTerm2.listSessions() else { break }
      if !sessions.allSessionIDs.contains(gatewaySessionID) {
        gone = true
        break
      }
      guard clock.now() < deadline,
        (try? await clock.sleep(for: configuration.pollInterval)) != nil
      else { break }
    } // End of loop waiting for the closed tab to leave the listing
    if gone { launches[gatewaySessionID] = nil }
    return (gone, detail + (gone ? ", gone" : ", still listed"))
  } // End of func closeDeadTab(_:)

  /// Records what the recovery did with one buried tab (no ids).
  func recordRecovery(_ text: String, failed: Bool, _ start: ContinuousClock.Instant) async {
    await diagnostics?.record(
      .attach, outcome: failed ? .failure : .success,
      durationMs: Self.milliseconds(clock.now() - start), detail: "buried launch tab: \(text)")
  }
}
