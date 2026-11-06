import Foundation

// "Detach other clients" (PLAN.md D37): keep this Mac's attachment of a session and have tmux
// detach the session's other clients, wherever they are.

extension AttachCoordinator {
  /// Detaches every other client of `target`'s session, on this Mac or any other, and keeps
  /// this Mac's attachment of it (PLAN.md D37). The session may live on this Mac or on a remote
  /// host: the command travels only through iTerm2's tmux connection of this Mac's attachment
  /// (no new ssh, script, file or request).
  ///
  /// It runs only with `confirmation` naming this session (`.detachOtherClients(of:
  /// target.key)`); any other confirmation ends `notConfirmed` before anything runs (no
  /// discovery, no iTerm2 request, no state published). Then:
  /// 1. It discovers the host (for its `uname -n` and current server) and asks the attachment
  ///    index (D16; the standard one when the coordinator's check is `.off`) which connections
  ///    show the session. None (iTerm2 not running, no server, none mapped): `notAttachedHere`.
  ///    A failure: `checkFailed(.attachmentCheck)`.
  /// 2. It waits until every other attachment's owning tab in this Mac's iTerm2 (the second one
  ///    listed on) is `Configuration.minimumLaunchTabAge` old, as `detach(session:on:)` does
  ///    before it ends a connection (iTerm2's short-lived session warning, D15); cancelling the
  ///    caller then sends nothing (`cancelled`).
  /// 3. It keeps the attachment "Show tab" focuses (`attach(_:)`'s choice): the first one in
  ///    listing order whose connection is still owned by the tab the index found it under. Its
  ///    identity check, right before sending, is the one `detach(session:on:)` uses (the
  ///    connection still shows that session of that server): another session or server, or an
  ///    answer that may have lost bytes, is `identityChanged`; no usable answer is
  ///    `checkFailed(.identityCheck)`; when every attachment's connection closed or changed
  ///    owner, `identityChanged`. Nothing is sent in any of these cases.
  /// 4. Through the same connection, bound to its owner, it reads its own client's name with
  ///    tmux's clock, and the session's clients with their creation times (read-only,
  ///    `OtherClientsCommands`, none of which can fail in tmux). Its own client not among them
  ///    is `identityChanged`; no other client is `nothingToDetach`; a failure, an unreadable
  ///    answer or another client whose pid, creation time or name is not valid is
  ///    `checkFailed(.clientListing)`. Nothing is sent in any of these cases.
  /// 5. It waits until every other client listed is `Configuration.minimumLaunchTabAge` old
  ///    (`OtherClient.ageWait(serverTime:minimumAge:)`: by tmux's clock, at most that long
  ///    from the listing), since a young one may be an attachment in this Mac's iTerm2 that
  ///    step 2's snapshot did not show yet; cancelling the caller then sends nothing
  ///    (`cancelled`).
  /// 6. For each other client in listing order (other attachments in this Mac's iTerm2 among
  ///    them): a read-only check right before, through the same connection, that a client with
  ///    that name, process id and creation time is still attached to the session (`gone`:
  ///    skipped, nothing sent), then `detach-client -t <name>` sent once (D13). The first
  ///    request that fails stops the call (`checkFailed(.clientListing)` or
  ///    `checkFailed(.send)`; a `detach-client` tmux did not confirm is
  ///    `checkFailed(.send(.tmuxCommandFailed))` and not counted), and so does a cancellation
  ///    (`cancelled`); otherwise it ends `detached(count:)` with the number of detaches tmux
  ///    confirmed, or `nothingToDetach` when every other client had left by its check. The
  ///    command never holds a runtime value other than the validated session id, process id,
  ///    creation time and name (PLAN.md D37: `attach-session -d`, which would need none, makes
  ///    iTerm2 close and reopen the session's windows).
  ///
  /// The check and the detach are two requests one round trip apart; tmux 3.8 and iTerm2's
  /// reply pairing allow no single bound command (PLAN.md D37), so within that round trip a
  /// checked client that switches to another session is detached from it, and one that ends
  /// makes `detach-client` fail (D37's residual).
  ///
  /// No outcome triggers a refresh by itself; the caller refreshes the session's row.
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
    checkBuriedTabs()
    let result = await detachOthers(of: key, on: target.host)
    await recordDetachOthers(result, hostID: target.host.id, duration: clock.now() - start)
    return result
  } // End of func detachOtherClients(of:confirmation:)

  /// The work of `detachOtherClients(of:confirmation:)` once the confirmation matched, without
  /// the diagnostics record.
  private func detachOthers(
    of key: SessionKey,
    on host: HostConfig
  ) async -> DetachOtherClientsResult {
    var result = DetachOtherClientsResult(key: key, outcome: .notAttachedHere)
    if case .failure(let failure) = Self.launchHost(for: host) {
      result.outcome = .checkFailed(.attachmentCheck(failure))
      return result
    }
    let indexHost: AttachmentIndex.Host
    switch await currentHost(host) {
    case .success(let found?): indexHost = found
    case .success(nil): return result
    case .failure(.cancelled):
      result.outcome = .cancelled
      return result
    case .failure(let failure):
      result.outcome = .checkFailed(.attachmentCheck(failure))
      return result
    }
    let snapshot: AttachmentSnapshot
    // Only the tabs watched before the listing can be judged by it (PLAN.md D29).
    let watched = watchedLaunchIDs()
    do {
      snapshot = try await detachIndex.snapshot(of: [indexHost])
      noteConnectionOwners(in: snapshot, watchedBefore: watched)
    } catch ITerm2Error.notRunning {
      return result
    } catch let error as ITerm2Error {
      result.outcome = .checkFailed(.attachmentCheck(.attachmentCheckFailed(error)))
      return result
    } catch {
      result.outcome = .cancelled
      return result
    }
    result.counts = snapshot.counts
    let attachments = snapshot.attachments(of: key)
    guard !attachments.isEmpty else { return result }
    let outcome = await detachOthers(of: key, through: attachments, host: indexHost, &result)
    result.outcome = outcome
    return result
  } // End of func detachOthers(of:on:)

  /// Steps 2–6 of `detachOtherClients(of:confirmation:)` for the session's attachments in this
  /// Mac's iTerm2, in listing order (at least one). Returns the outcome; notes in `result` the
  /// attachment chosen to be kept and, as they become known, the other attachments here, the
  /// other clients listed, the wait for young ones, and those gone before their check and
  /// detached.
  private func detachOthers(
    of key: SessionKey,
    through attachments: [AttachmentSnapshot.Attachment],
    host: AttachmentIndex.Host,
    _ result: inout DetachOtherClientsResult
  ) async -> DetachOtherClientsResult.Outcome {
    // 2. The other attachments' tabs must be old enough before tmux ends their connections:
    // counted from the opening for launch tabs this coordinator opened, else from now, when the
    // snapshot that revealed them has completed (as `detach(session:on:)` counts).
    let observedAt = clock.now()
    let notBefore = attachments.dropFirst().map { attachment in
      (launches[attachment.owningSessionID]?.openedAt ?? observedAt)
        + configuration.minimumLaunchTabAge
    }.max()
    if let notBefore, notBefore > clock.now() {
      do {
        try await clock.sleep(for: notBefore - clock.now())
      } catch {
        return .cancelled
      }
    }
    // 3. The kept attachment and its identity, right before anything else is asked of it.
    var kept: AttachmentSnapshot.Attachment?
    for attachment in attachments {
      let identification: AttachmentIndex.Identification
      do {
        identification = try await detachIndex.identify(
          connectionID: attachment.connectionID, owningSessionID: attachment.owningSessionID)
      } catch {
        return .cancelled
      }
      switch identification {
      case .stale(.requestFailed(.tmuxConnectionNotOwned)):
        // Closed, or its short id now names another tab's connection: `attach(_:)`'s focus
        // skips it the same way.
        continue
      case .stale(let reason):
        result.kept = attachment
        return .checkFailed(.identityCheck(reason))
      case .nonUTF8:
        result.kept = attachment
        return .identityChanged
      case .reported(let reported):
        result.kept = attachment
        guard AttachmentIndex.map(reported, among: [host]) == .mapped(key) else {
          return .identityChanged
        }
      }
      kept = attachment
      break
    } // End of loop over the session's attachments
    guard let kept else { return .identityChanged }
    result.otherAttachmentsHere = attachments.count - 1
    // 4. tmux's clock and the session's other clients, read through the kept connection.
    let own: OtherClientsCommands.Own
    let others: [OtherClient]
    do {
      let answer = try await iTerm2.sendTmuxCommand(
        OtherClientsCommands.ownClientAndTime, connectionID: kept.connectionID,
        ownedBy: kept.owningSessionID)
      guard let read = OtherClientsCommands.readOwn(answer) else {
        return .checkFailed(.clientListing(nil))
      }
      own = read
      let listing = try await iTerm2.sendTmuxCommand(
        OtherClientsCommands.clients(of: key.sessionID), connectionID: kept.connectionID,
        ownedBy: kept.owningSessionID)
      switch OtherClientsCommands.readListing(listing, ownName: own.name) {
      case .others(let listed): others = listed
      case .ownNotListed: return .identityChanged
      case .unreadable: return .checkFailed(.clientListing(nil))
      }
    } catch let error as ITerm2Error {
      return .checkFailed(.clientListing(error))
    } catch {
      return .cancelled
    }
    result.listedOthers = others.count
    // 5. Every client detached must be old enough, whether or not the snapshot showed it.
    let listedAt = clock.now()
    let ageWait =
      others.map {
        $0.ageWait(serverTime: own.serverTime, minimumAge: configuration.minimumLaunchTabAge)
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
    // 6. Each other client: checked right before, then detached by name, once.
    for client in others {
      guard !Task.isCancelled else { return .cancelled }
      do {
        let answer = try await iTerm2.sendTmuxCommand(
          OtherClientsCommands.check(client, of: key.sessionID),
          connectionID: kept.connectionID, ownedBy: kept.owningSessionID)
        switch OtherClientsCommands.readCheck(answer, for: client) {
        case .present: break
        case .gone:
          result.goneBeforeDetach += 1
          continue
        case .unreadable: return .checkFailed(.clientListing(nil))
        }
      } catch let error as ITerm2Error {
        return .checkFailed(.clientListing(error))
      } catch {
        return .cancelled
      }
      guard !Task.isCancelled else { return .cancelled }
      do {
        // Confirmed only with its output: an answer without it (tmux's `%error`, such as a
        // client that ended since its check) is `tmuxCommandFailed`, never counted.
        _ = try await iTerm2.sendTmuxCommand(
          OtherClientsCommands.detach(client), connectionID: kept.connectionID,
          ownedBy: kept.owningSessionID)
      } catch let error as ITerm2Error {
        return .checkFailed(.send(error))
      } catch {
        // Cancelled while the request was out: it may have reached tmux.
        return .checkFailed(.send(.disconnected))
      }
      result.detachedClients += 1
    } // End of loop over the session's other clients
    return result.detachedClients > 0
      ? .detached(count: result.detachedClients) : .nothingToDetach
  } // End of func detachOthers(of:through:host:_:)

  /// Records how `detachOtherClients(of:confirmation:)` ended: its outcome, counts and problem
  /// kinds and its duration only (no ids or names).
  private func recordDetachOthers(
    _ result: DetachOtherClientsResult,
    hostID: UUID,
    duration: Duration
  ) async {
    var detail = "detach other clients: \(result.outcome.kind)"
    detail += ", \(result.detachedClients) of \(result.listedOthers) client(s) detached"
    if result.goneBeforeDetach > 0 { detail += ", \(result.goneBeforeDetach) gone first" }
    if result.ageWait > .zero {
      detail += ", waited \(Self.milliseconds(result.ageWait)) ms for young clients"
    }
    if result.otherAttachmentsHere > 0 {
      detail += ", \(result.otherAttachmentsHere) other attachment(s) here"
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
      durationMs: Self.milliseconds(duration), detail: detail)
  } // End of func recordDetachOthers(_:hostID:duration:)
} // End of extension AttachCoordinator
