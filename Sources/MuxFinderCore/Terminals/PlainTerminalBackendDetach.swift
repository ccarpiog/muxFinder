import Foundation

// The plain backend's detaches (PLAN.md D38, requirement 6; D37): through tmux only, with the
// bound commands of D38, never by closing a window.

extension PlainTerminalBackend {
  /// Detaches the backend's own attachment of the session `key` (PLAN.md D38): the recorded
  /// client only, with the bound `PlainClientDetach` (one tmux command on This Mac, one
  /// BatchMode ssh call on an SSH host, where the client was attached), never by closing its
  /// window. With no attachment of the session the result is `nothingAttached` and nothing
  /// runs.
  ///
  /// `detached` once tmux detached the client (the attachment is dropped, and the helper's
  /// result is waited for within the result budget and taken: the attachment is over); the
  /// bound check's refusal (the client, its session or the server is not the recorded one) is
  /// `notSent` and drops the attachment too; a run that failed (its outcome unknown) is
  /// `notClosed`; a command that cannot be written is `checkFailed` (`clientCheckFailed`); a
  /// caller cancelled before anything ran `cancelled`.
  public func detach(session key: SessionKey, on host: HostConfig) async -> SessionDetachResult {
    let start = clock.now()
    pruneEndedAttachments()
    let result = await detachAttachment(of: key)
    var detail = "plain detach: \(result.outcome.rawValue)"
    if let failure = result.plainDetach?.failure { detail += " (\(failure.kind))" }
    await diagnostics?.record(
      .attach,
      outcome: result.outcome == .detached || result.outcome == .nothingAttached
        ? .success : .failure,
      hostID: host.id.uuidString,
      durationMs: AttachCoordinator.milliseconds(clock.now() - start), detail: detail)
    return result
  } // End of func detach(session:on:)

  /// The work of `detach(session:on:)`, without the diagnostics record.
  private func detachAttachment(of key: SessionKey) async -> SessionDetachResult {
    guard let attachment = attachments[key] else {
      return SessionDetachResult(key: key, outcome: .nothingAttached)
    }
    var plain = PlainDetachResult(client: attachment.client)
    guard !Task.isCancelled else {
      plain.failure = .cancelled
      return SessionDetachResult(key: key, outcome: .cancelled, plainDetach: plain)
    }
    let outcome: SessionDetachResult.Outcome
    var checkFailure: AttachFailure?
    switch await tmux.detach(
      attachment.client.client, from: attachment.client.session, at: attachment.target)
    {
    case .success(.detached):
      plain.outcome = .detached
      dropAttachment(key, launchID: attachment.launchID)
      plain.helperResult = await waitForResult(attachment.launchID)
      outcome = .detached
    case .success:
      plain.outcome = .notThisClient
      dropAttachment(key, launchID: attachment.launchID)
      outcome = .notSent
    case .failure(.notWritable):
      plain.failure = .notWritable
      checkFailure = .clientCheckFailed(.notWritable)
      outcome = .checkFailed
    case .failure(let failure):
      plain.failure = failure
      outcome = .notClosed
    }
    return SessionDetachResult(
      key: key, outcome: outcome, checkFailure: checkFailure, plainDetach: plain)
  } // End of func detachAttachment(of:)

  /// Waits (within the result budget) for the helper's result of `launchID` and takes it (the
  /// attachment is over, so its early report goes with it).
  private func waitForResult(_ launchID: LaunchToken) async -> LaunchResult? {
    let deadline = clock.now() + configuration.resultBudget
    while true {
      if let result = try? store.takeResult(launchID) { return result }
      guard clock.now() < deadline,
        (try? await clock.sleep(for: configuration.pollInterval)) != nil
      else { return nil }
    }
  } // End of func waitForResult(_:)

  /// "Detach other clients…" for the plain backend (PLAN.md D37, D38): keeps the backend's own
  /// attachment of `target`'s session (its recorded client) and detaches every other client of
  /// the session, wherever it is.
  ///
  /// Only with `confirmation` naming the session (else `notConfirmed`, nothing run); with no
  /// attachment of the session, `notAttachedHere` and nothing runs. Then:
  /// 1. One read-only command (locally, or over BatchMode ssh) prints tmux's clock and the
  ///    session's clients (`PlainSessionClients`); a failure is
  ///    `checkFailed(.plainClientListing)`. The kept client must be among them with its
  ///    recorded name, pid and creation time, else `identityChanged`; no other client is
  ///    `nothingToDetach`.
  /// 2. Every other client must be `minimumLaunchTabAge` (10 s) old by tmux's clock
  ///    (`OtherClient.ageWait(serverTime:minimumAge:)`, D37's age guard); a cancelled wait is
  ///    `cancelled`, nothing sent.
  /// 3. Each other client in listing order is detached with the bound `PlainClientDetach`
  ///    keeping the kept client (`PlainClientDetach.arguments(of:keeping:in:)`), in which the
  ///    server itself checks, server-wide, that exactly one client has that name and it has
  ///    that pid and creation time on the recorded session, and that the kept client still
  ///    holds the session the same way (one command, nothing in between; a review fix of
  ///    I-12c1). Right before each detach the attachment must still be the backend's record of
  ///    the session, its helper's result absent (a file-only peek), else `identityChanged`
  ///    with nothing more sent (an ended one is dropped). A refusal is told apart by the
  ///    read-only `PlainClientPresence` check of the kept client: present counts the other
  ///    client as gone before its detach; not present drops the attachment and ends the call
  ///    `identityChanged`, nothing more sent; a check that cannot run is
  ///    `checkFailed(.plainClientListing)`. A failed detach stops the call
  ///    (`checkFailed(.plainDetach)`), and so does a cancellation (`cancelled`). The detaches
  ///    tmux confirmed before any of these stops stay counted in `detachedClients`.
  public func detachOtherClients(
    of target: AttachTarget,
    confirmation: DetachOtherClientsConfirmation
  ) async -> DetachOtherClientsResult {
    let key = target.key
    guard confirmation.key == key else {
      let result = DetachOtherClientsResult(key: key, outcome: .notConfirmed)
      await recordDetachOthers(result, hostID: target.host.id, duration: .zero)
      return result
    }
    let start = clock.now()
    pruneEndedAttachments()
    var result = DetachOtherClientsResult(key: key, outcome: .notAttachedHere)
    if let attachment = attachments[key] {
      result.keptPlainClient = attachment.client
      result.outcome = await detachOthers(keeping: attachment, &result)
    }
    await recordDetachOthers(result, hostID: target.host.id, duration: clock.now() - start)
    return result
  } // End of func detachOtherClients(of:confirmation:)

  /// Steps 1–3 of `detachOtherClients(of:confirmation:)` around `attachment`'s client. Returns
  /// the outcome; notes in `result` the other clients listed, the age wait, and those gone
  /// before their detach and detached.
  private func detachOthers(
    keeping attachment: PlainAttachment,
    _ result: inout DetachOtherClientsResult
  ) async -> DetachOtherClientsResult.Outcome {
    let session = attachment.client.session
    // 1. tmux's clock and the session's clients.
    let listing: PlainSessionClients
    switch await tmux.sessionClients(of: session.sessionID, at: attachment.target) {
    case .success(let read): listing = read
    case .failure(.cancelled): return .cancelled
    case .failure(let failure): return .checkFailed(.plainClientListing(failure))
    }
    let kept = attachment.client.client
    guard listing.clients.contains(kept) else { return .identityChanged }
    let others = listing.clients.filter { $0 != kept }
    result.listedOthers = others.count
    guard !others.isEmpty else { return .nothingToDetach }
    // 2. Every client detached must be old enough by tmux's clock.
    let listedAt = clock.now()
    let ageWait =
      others.map {
        $0.ageWait(serverTime: listing.serverTime, minimumAge: configuration.minimumLaunchTabAge)
      }.max() ?? .zero
    if ageWait > .zero {
      result.ageWait = ageWait
      let remaining = listedAt + ageWait - clock.now()
      if remaining > .zero {
        do {
          try await clock.sleep(for: remaining)
        } catch {
          return .cancelled
        }
      }
    }
    // 3. Each other client: the bound detach, once, which the server runs only while the kept
    // client still holds the session; and only while the attachment is still the record.
    let key = result.key
    for client in others {
      guard !Task.isCancelled else { return .cancelled }
      guard isStillRecorded(attachment, of: key) else { return .identityChanged }
      switch await tmux.detach(client, keeping: kept, from: session, at: attachment.target) {
      case .success(.detached):
        result.detachedClients += 1
      case .success:
        // Refused: the other client left, or the kept one no longer holds the session.
        switch await keptClientHolds(attachment, of: key) {
        case .success(true): result.goneBeforeDetach += 1
        case .success(false): return .identityChanged
        case .failure(.cancelled): return .cancelled
        case .failure(let failure): return .checkFailed(.plainClientListing(failure))
        }
      case .failure(let failure):
        return .checkFailed(.plainDetach(failure))
      }
    } // End of loop over the session's other clients
    return result.detachedClients > 0
      ? .detached(count: result.detachedClients) : .nothingToDetach
  } // End of func detachOthers(keeping:_:)

  /// Whether `attachment` is still the backend's record of `key` and its helper has not ended
  /// (a file-only peek at its result; an ended one is dropped). A record dropped or replaced
  /// meanwhile (a detach, a stale record found by an attach) is no longer kept.
  private func isStillRecorded(_ attachment: PlainAttachment, of key: SessionKey) -> Bool {
    if (try? store.peekResult(attachment.launchID)) != nil {
      dropAttachment(key, launchID: attachment.launchID)
    }
    return attachments[key] == attachment
  }

  /// After a refused bound detach: whether `attachment`'s client still holds its session (the
  /// read-only `PlainClientPresence` check). Not present drops the attachment; a check that
  /// cannot run is its failure.
  private func keptClientHolds(
    _ attachment: PlainAttachment,
    of key: SessionKey
  ) async -> Result<Bool, PlainTmuxCommandFailure> {
    switch await tmux.presence(
      of: attachment.client.client, in: attachment.client.session, at: attachment.target)
    {
    case .success(.present):
      return .success(true)
    case .success:
      dropAttachment(key, launchID: attachment.launchID)
      return .success(false)
    case .failure(let failure):
      return .failure(failure)
    }
  } // End of func keptClientHolds(_:of:)

  /// Records how `detachOtherClients(of:confirmation:)` ended: its outcome, counts and problem
  /// kinds and its duration only (no ids or names).
  private func recordDetachOthers(
    _ result: DetachOtherClientsResult,
    hostID: UUID,
    duration: Duration
  ) async {
    var detail = "plain detach other clients: \(result.outcome.kind)"
    detail += ", \(result.detachedClients) of \(result.listedOthers) client(s) detached"
    if result.goneBeforeDetach > 0 { detail += ", \(result.goneBeforeDetach) gone first" }
    if result.ageWait > .zero {
      detail += ", waited \(AttachCoordinator.milliseconds(result.ageWait)) ms for young clients"
    }
    if case .checkFailed(let problem) = result.outcome {
      detail += " (\(problem.kind)\(problem.detail.map { ": \($0)" } ?? ""))"
    }
    let success: Bool
    switch result.outcome {
    case .detached, .nothingToDetach, .notAttachedHere: success = true
    default: success = false
    }
    await diagnostics?.record(
      .attach, outcome: success ? .success : .failure, hostID: hostID.uuidString,
      durationMs: AttachCoordinator.milliseconds(duration), detail: detail)
  } // End of func recordDetachOthers(_:hostID:duration:)
} // End of extension PlainTerminalBackend
