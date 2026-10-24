import AppKit
import Darwin
import Foundation
import MuxFinderCore

/// `muxfinder-probe e2e-bury --local | --ssh <destination>`: the real check of PLAN.md D29 (the
/// launch tab hidden once attached), first the spike of Phase 13a, run through the coordinator
/// since Phase 13c. Every attach goes through an `AttachCoordinator` that buries its launch tab
/// itself (step 10 of the attach, `AttachResult.burial`), as the app does, over a request store
/// that can set the helper's test switch (`BuryRequestStore`) and through
/// `RecordingITerm2Integration`, which records each bury, restore and `Close` of the
/// coordinator's (so a detach step can prove the launch tab left by itself) and each bury's
/// answer (so step 7 can tell a bury that was sent from one that was refused), and runs a hook
/// right before each bury (`beforeCoordinatorBury`: a look at where the tab is, and step 7's
/// detach released together with the bury). The harness's own requests go to the iTerm2
/// client directly. Steps 7 and 11 are judged by `BuryRaceOutcome` and `KilledLaunchTabWatch`
/// (in `MuxFinderCore`, unit-tested).
///
/// iTerm2's "Automatically bury the tmux client session after connecting" setting
/// (`AutoHideTmuxClientSession`, off by default) changes what happens: with it on, iTerm2
/// buries each launch tab itself once its first tmux tab opens (S6), so the coordinator's bury
/// answers `OK` on a buried tab (S2), and restores it itself when tmux ends (S5). The run never
/// reads or writes that setting and passes either way; it tells it from what iTerm2 does (where
/// the tab is right before the coordinator's bury, and step 9's tmux end without `Disinter`)
/// and prints what it saw at the end.
///
/// Steps (each prints one PASS or FAIL line, with `note` and `OBSERVATION` lines; the first
/// failure stops the run, then cleanup runs):
/// 1. **create session:** `muxfinder-test-<hex>`, one pane running `sleep 600`.
/// 2. **discover:** discovery lists it exactly as created.
/// 3. **attach (bury):** confirmed, its first tab activated, `burial` `buried`, and the launch
///    tab in `buried_sessions` and in no tab (`checkBuried`); the helper's argv digest records
///    its attach child's process id.
/// 4. **detach within 10 s:** at `earlyDetachAge`, a bound `detach-client` from the harness
///    (the coordinator waits until the tab is 10 s old; a detach inside the session or by
///    another client does not); the helper exits 0, and the buried launch tab leaves both
///    iTerm2's tabs and `buried_sessions` by itself (`checkLaunchTabLeft`) before any cleanup;
///    the session survives with no client.
/// 5. **reattach:** as step 3.
/// 6. **detach after 10 s:** the coordinator's detach (as Detach in the app), then the same
///    checks, its tmux tabs closed too.
/// 7. **detach at the bury:** D29's race for real: an attach whose bury the hook releases
///    together with a bound `detach-client` of the harness, once the tab is `earlyDetachAge`
///    old, neither waiting for the other's answer (attempt 1: both let go at once; later
///    attempts: the bury first, the detach the moment the recorder forwarded it). The bury must
///    have been sent and answered `OK` (`RecordingITerm2Integration.buryAnswers(of:)`) and
///    `burial` be `buried` (the helper's restore undoes it) or `restoredAfterEnd` (the
///    coordinator's check after the bury saw tmux had ended and restored the tab; that one
///    restore is allowed); then the step 4 checks, and the order of the detach, the bury, its
///    answer, the helper's result and first restore and the attach's return is observed. A bury
///    its ownership check refused (`failed` `tmuxConnectionNotOwned`: the connection was gone
///    first, nothing buried) is not the race: it is reported, its tab must still leave by
///    itself, and the step attaches and races again, at most `raceAttempts` times in all, then
///    fails.
/// 8. **attach without Disinter:** as step 3, the request carrying the helper's test switch
///    (`testSuppressDisinter`: its restores write no `Disinter`).
/// 9. **dead tab recovery (b, d):** a bound detach at `earlyDetachAge`. With iTerm2's
///    auto-hide setting on, iTerm2 restores the tab itself at the tmux end, and it must leave
///    by itself. With it off, the tab stays buried, becomes a dead buried session once its
///    helper exits (S4), and the coordinator's recovery must restore and close it (a forced
///    `Close` of a buried session, spike (d)) within `recoveryWait` of the helper's result.
/// 10. **attach for the kill:** as step 3.
/// 11. **kill attach child (e):** SIGKILL of only the helper's attach child (the process id its
///     digest recorded, checked to be the helper's child running the expected executable:
///     locally tmux, remotely the local `/usr/bin/ssh`, killed only when `ssh -G` shows no
///     connection sharing) while the coordinator's bury holds, then a watch until the helper
///     is `lifetimeMargin` past its minimum lifetime (at least `killWatch`, at most
///     `killWatchLimit`): the helper's result must be `childSignaled(9)`, exit 137 (D14); the
///     tab must come back in a tab and, at every later look, still be there (never buried
///     again, never gone), with an answered status report of the helper's (so the explanation
///     it wrote next is drawn); no `Close` and no further bury of the coordinator's may touch
///     it; the helper must still run (waiting for Return) at the end; and the session must
///     survive. Who brought it back (iTerm2, the helper or the coordinator's recovery) is
///     observed; Return is never pressed (no keystrokes).
/// 12. **close after the kill:** the same requirements once more right before the close (the
///     tab still in a tab, its helper alive, nothing of the coordinator's on it); then the
///     killed attach's launch tab closed (forced) where it is listed, restored and closed again
///     if that left it; the helper must end and no connection of the tab may stay listed. When
///     step 11 skipped the kill, a clean detach through the coordinator instead.
///
/// **Cleanup** (step 13, on every way out, SIGINT and SIGTERM included): the hook is cleared;
/// once every launch tab of the run is 10 s old, a bound `detach-client` for each connection
/// one of them owns (never for the killed attach's, whose client is gone), then each launch tab
/// of the run still listed is restored if buried and closed (forced), every status checked and
/// its absence verified. A launch tab that still owns a live connection is left open, and the
/// session alive, with the commands to finish by hand. The session is killed only while it is
/// still exactly the created one; the helper results nobody took and the test-mode marker are
/// removed.
///
/// Safety (PLAN.md *Unattended-run rules*): only its own session, launch tabs and their tmux
/// connections are ever asked, buried, detached, closed or killed; no other tab, session or
/// connection is touched, nothing is typed into any session, no iTerm2 preference is read or
/// written, and remotely nothing is written on the host. Every wait is bounded.
actor E2EBuryRun {
  /// Which host the run uses.
  enum Kind: Sendable, Equatable {
    /// This Mac's default tmux server.
    case local
    /// The default tmux server of the host at this SSH destination.
    case remote(destination: String)
  }

  /// The number of steps, cleanup included.
  static let stepCount = 13
  /// The coordinator's budgets (the defaults, as in the app).
  static let configuration = AttachCoordinator.Configuration()
  /// How old a launch tab must be before the run ends it by closing it or killing the session
  /// (iTerm2's short-lived session warning, PLAN.md D15).
  static let minimumTabAge = configuration.minimumLaunchTabAge
  /// How old the launch tab is when steps 4, 7 and 9 detach it: past iTerm2's 3 s short-lived
  /// limit, but before the helper's 10 s minimum lifetime and the coordinator's own 10 s wait
  /// before a detach.
  static let earlyDetachAge: Duration = .seconds(5)
  /// How long a confirmed attach's launch tab may take to show only in `buried_sessions` after
  /// the attach returned (the coordinator buried it before returning).
  static let buryListing: Duration = .seconds(5)
  /// How long a detached launch tab may take to leave both iTerm2's tabs and `buried_sessions`
  /// by itself: the helper restores it (one bounded 2 s exchange), holds until its 10 s
  /// minimum lifetime, makes its last restore and exits, and the tab closes.
  static let strandedGatewayWait: Duration = .seconds(10)
  /// How long after the helper's result step 9 waits for the coordinator's recovery of a dead
  /// buried tab: the close delay after the result was first seen, two timer intervals (the
  /// look that sees the result, the one that starts the recovery), the `Close` budget and a
  /// margin.
  static let recoveryWait: Duration =
    configuration.buriedTabCloseDelay + configuration.buriedTabCheckInterval * 2
    + configuration.buriedTabCloseBudget + .seconds(5)
  /// How many attaches step 7 may race before an ownership refusal on each fails it.
  static let raceAttempts = 3
  /// How long step 7's detach, when the bury leads, waits for the recorder to forward the bury.
  static let raceBuryWait: Duration = .seconds(2)
  /// How long step 11 watches after the kill at least.
  static let killWatch: Duration = .seconds(8)
  /// How long past the helper's minimum lifetime step 11 watches.
  static let lifetimeMargin: Duration = .seconds(2)
  /// How long step 11 watches after the kill at most.
  static let killWatchLimit: Duration = .seconds(20)
  /// The pause between two polls.
  static let pollInterval: Duration = .milliseconds(200)
  /// The pause between two polls while step 11 watches.
  static let killPollInterval: Duration = .milliseconds(100)
  /// The pause between two polls of step 11 once the tab is back and the connection and its
  /// tabs are gone.
  static let settledPollInterval: Duration = .milliseconds(250)

  /// Which host.
  let kind: Kind
  /// tmux on the host under test.
  let tmux: any HarnessTmux
  /// The helper iTerm2 runs.
  let helperPath: LaunchHelperPath
  /// The iTerm2 client every step shares.
  let client = ITerm2APIClient()
  /// What the coordinator talks to: `client`, with each bury, restore and `Close` recorded
  /// before it is sent (`checkLaunchTabLeft`) and the hook run before each bury
  /// (`beforeCoordinatorBury`, set in setup).
  let coordinatorITerm2: RecordingITerm2Integration
  /// The real launch directory.
  let store = LaunchStore()
  /// The coordinator's request store (the real one, with the test switch).
  let requests: BuryRequestStore
  /// Real discovery.
  let discovery = DiscoveryProbe()
  /// The host under test.
  let host: HostConfig
  /// The coordinator's updates, including every launch tab it opened.
  let recorder = UpdateRecorder()
  /// The attaches and the coordinator's detaches (no existing-attachment check, so no other
  /// connection is ever asked).
  let coordinator: AttachCoordinator
  /// The test session's name.
  let sessionName = "muxfinder-test-" + String(format: "%08x", UInt32.random(in: .min ... .max))

  /// One attachment of the run, as the attach step left it.
  struct Attachment: Sendable {
    /// The launch.
    let launchID: LaunchToken
    /// The launch tab's session.
    let gateway: String
    /// Its tmux connection.
    let connectionID: String
    /// The helper's argv digest when the attach was confirmed.
    let digest: LaunchArgvDigest
  }

  /// Which of step 7's two requests the hook lets go first. Neither ever waits for the other's
  /// answer.
  enum RaceLead: String, Sendable {
    /// The hook starts the detach in a task of its own and returns at once, so the bury goes
    /// out in the same instant.
    case together = "the detach and the bury released together"
    /// The detach goes out the moment the recorder forwarded the bury to the iTerm2 client, so
    /// the bury's ownership check is on the wire first.
    case buryFirst = "the bury released first, the detach right behind it"
  }

  /// Step 7's race, as the hook ran it.
  struct RaceArm: Sendable {
    /// Which request goes first.
    let lead: RaceLead
    /// The launch tab it was bound to, once the hook took it.
    var gateway: String?
    /// How old the tab was when the race was released.
    var age: String?
    /// The detach running alongside the bury; only the step awaits its answer.
    var detach: Task<DetachAnswer, Never>?
  }

  /// How step 7's detach went, as wall-clock times (like the helper's digest).
  struct DetachAnswer: Sendable {
    /// When `detach-client` was handed to the client.
    var sentAt: Date
    /// When iTerm2 answered it.
    var answeredAt: Date?
    /// Why it failed, if it did.
    var failure: String?
  }

  /// What one of step 7's attempts left: the judgement, and the step's detail when it raced.
  struct RaceAttempt: Sendable {
    /// The judgement.
    let outcome: BuryRaceOutcome
    /// The step's detail.
    let detail: String
  }

  /// What step 11 saw after the kill, as wall-clock times (like the helper's digest).
  struct KillTimeline: Sendable {
    /// The helper's result, once seen (peeked).
    var result: LaunchResult?
    /// When the tab's tmux connection left `ListConnections`.
    var connectionGone: Date?
    /// When the connection's tmux tabs were gone.
    var tabsGone: Date?
    /// How many restores of the tab the coordinator had sent by the time a look first saw it
    /// in a tab (its recovery after the helper's failure result may have brought the tab back).
    var coordinatorRestoresByThen = 0
    /// Every look at the launch tab since the kill, and their judgement.
    var watch = KilledLaunchTabWatch()
  }

  /// The created session, once known.
  private var created: CreatedSession?
  /// When step 1 started `new-session` (seconds since 1970).
  private var creationStartedAt: Int64?
  /// The attach target discovery found.
  private var target: AttachTarget?
  /// The current attachment.
  private var current: Attachment?
  /// The latest argv digest of each launch, as taken from the launch directory.
  private var digests: [LaunchToken: LaunchArgvDigest] = [:]
  /// Every launch of the run, so cleanup takes the helper results nobody took.
  private var launchIDs: [LaunchToken] = []
  /// Launch tabs whose attach child step 11 killed (their tmux connection, if still listed, has
  /// no client: a `detach-client` would only be typed into the helper).
  private var killedGateways: Set<String> = []
  /// Whether step 11 killed the attach child (otherwise step 12 detaches cleanly).
  private var killed = false
  /// Per launch tab (its session id), where iTerm2 listed it right before the coordinator's
  /// bury went out (`nil` value: the listing failed).
  private var preBuryPlaces: [String: GatewayPlace?] = [:]
  /// Whether iTerm2 restored step 9's launch tab itself at the tmux end without `Disinter` (its
  /// auto-hide setting on, S5); `nil` until step 9 saw it.
  private var restoredAtEndWithoutDisinter: Bool?
  /// Step 7's race for the hook: armed (no gateway yet) while step 7 attaches, filled in by the
  /// hook.
  private var raceArm: RaceArm?
  /// What step 11 saw, for step 12's last look before the close.
  private var killTimeline: KillTimeline?
  /// Whether ssh shares connections for the destination (remote runs).
  private var sharing: SSHConnectionSharing.Verdict = .unknown
  /// `tmux -V`, once the header asked.
  private var tmuxVersion: String?
  /// Whether setup turned on the helper's test mode.
  private var markerCreated = false
  /// Whether setup succeeded.
  private var setUp = false
  /// Steps that passed.
  private(set) var passedCount = 0
  /// The observation and note lines of the current step.
  private var lines: [String] = []

  /// Creates the run.
  init(kind: Kind, tmux: any HarnessTmux, helperPath: LaunchHelperPath) {
    self.kind = kind
    self.tmux = tmux
    self.helperPath = helperPath
    switch kind {
    case .local:
      host = HostConfig(displayName: "This Mac", mode: .local)
    case .remote(let destination):
      host = HostConfig(displayName: "Remote host", mode: .ssh, sshDestination: destination)
    }
    requests = BuryRequestStore(base: store)
    coordinatorITerm2 = RecordingITerm2Integration(base: client)
    let recorder = self.recorder
    // The coordinator buries each launch tab once attached (PLAN.md D29), as in the app.
    coordinator = AttachCoordinator(
      iTerm2: coordinatorITerm2, discovery: discovery, store: requests, helperPath: helperPath,
      configuration: Self.configuration, existingAttachments: .off,
      onUpdate: { recorder.record($0) })
  } // End of init(kind:tmux:helperPath:)

  /// The command's name for the output.
  nonisolated var name: String {
    kind == .local ? "e2e-bury --local" : "e2e-bury --ssh"
  }

  /// Writes `line` to standard output at once.
  nonisolated func output(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
  }

  /// Prints the versions this run uses.
  func printHeader() async {
    let iTerm2Version =
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2")
      .flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
      ?? "unknown"
    tmuxVersion = await tmux.version()
    output(
      "\(name): macOS \(ProcessInfo.processInfo.operatingSystemVersionString), iTerm2 "
        + "\(iTerm2Version), \(tmuxVersion ?? "tmux unknown") \(tmux.location), helper "
        + "\(helperPath.path), session \(sessionName)")
  } // End of func printHeader()

  // MARK: - Steps

  /// Setup, then steps 1–12, stopping at the first failure. Cleanup is `cleanUp()`.
  func runSteps() async {
    guard await setUpRun() else { return }
    guard await step(1, "create session", { try await self.createSession() }),
      await step(2, "discover", { try await self.discoverSession() }),
      await step(3, "attach (bury)", { try await self.attachStep() }),
      await step(4, "detach within 10 s", { try await self.detachEarly() }),
      await step(5, "reattach", { try await self.attachStep() }),
      await step(6, "detach after 10 s", { try await self.detachThroughCoordinator() }),
      await step(7, "detach at the bury", { try await self.detachAtBuryStep() }),
      await step(
        8, "attach without Disinter", { try await self.attachStep(suppressingDisinter: true) }),
      await step(9, "dead tab recovery (b, d)", { try await self.deadTabRecovery() }),
      await step(10, "attach for the kill", { try await self.attachStep() }),
      await step(11, "kill attach child (e)", { try await self.killAttachChild() }),
      await step(12, "close after the kill", { try await self.closeAfterKill() })
    else { return }
  } // End of func runSteps()

  /// Runs one step and prints its PASS or FAIL line, then its observation and note lines.
  /// Returns whether it passed.
  private func step(
    _ number: Int,
    _ title: String,
    _ body: () async throws -> String
  ) async -> Bool {
    let start = ContinuousClock.now
    lines.removeAll()
    let passed: Bool
    let detail: String
    do {
      detail = try await body()
      passed = true
    } catch let failure as StepFailure {
      (passed, detail) = (false, failure.detail)
    } catch is CancellationError {
      (passed, detail) = (false, "interrupted")
    } catch let error as ITerm2Error {
      let hint =
        error == .timedOut || error == .notSent(.timedOut)
        ? " iTerm2 stopped answering its API; a modal iTerm2 dialog may be open." : ""
      (passed, detail) = (false, "\(error.errorDescription ?? error.kind) [\(error.kind)]\(hint)")
    } catch {
      (passed, detail) = (false, "\(error)")
    }
    output(
      "\(passed ? "PASS" : "FAIL") \(number) \(title) "
        + "(\(milliseconds(ContinuousClock.now - start)) ms): \(detail)")
    for line in lines { output("  \(line)") }
    if passed { passedCount += 1 }
    return passed
  } // End of func step(_:_:_:)

  /// Adds an `OBSERVATION` line to the current step.
  private func observe(_ text: String) {
    lines.append("OBSERVATION: \(text)")
  }

  /// Adds a note line to the current step.
  private func note(_ text: String) {
    lines.append("note: \(text)")
  }

  /// Milliseconds of an optional duration, or -1.
  private func ms(_ duration: Duration?) -> Int {
    duration.map(milliseconds) ?? -1
  }

  /// Checks iTerm2's API (and, remotely, that the host answers over ssh and whether ssh shares
  /// connections), turns on the helper's test mode and sets the hook run before each of the
  /// coordinator's buries.
  private func setUpRun() async -> Bool {
    if case .remote(let destination) = kind {
      guard tmuxVersion != nil else {
        output(
          "FAIL setup: \(destination) did not answer tmux -V over ssh (BatchMode); check that it "
            + "is reachable with key authentication and has tmux")
        return false
      }
      sharing = await SSHConnectionSharing.check(destination: destination)
    }
    let status = await client.status()
    guard status.isConnected else {
      let kind = status.error?.kind ?? "unknown"
      let hint = kind == "timedOut" ? "; a modal iTerm2 dialog may be open" : ""
      output("FAIL setup: iTerm2's API is not reachable (\(kind)\(hint))")
      return false
    }
    do throws(LaunchStoreError) {
      try store.createTestModeMarker()
      markerCreated = true
      _ = try store.takeArgvDigests()
    } catch {
      output("FAIL setup: the launch directory is not usable (\(error.description))")
      return false
    }
    guard let foreign = try? await client.listTmuxConnections().count else {
      output("FAIL setup: iTerm2's tmux connections could not be listed")
      return false
    }
    await coordinatorITerm2.setBeforeBury { [weak self] sessionID, connectionID in
      await self?.beforeCoordinatorBury(sessionID: sessionID, connectionID: connectionID)
    }
    setUp = true
    var line =
      "setup: iTerm2 API connected (protocol \(status.protocolVersion ?? "?")), helper test mode "
      + "on, the coordinator buries its launch tabs (PLAN.md D29); \(foreign) tmux "
      + "connection(s) this run did not open, never asked"
    if case .remote = kind {
      line +=
        "; ssh connection sharing for the destination: \(sharing) (step 11 kills the local ssh "
        + "child only when it is off)"
    }
    output(line)
    return true
  } // End of func setUpRun()

  /// The hook (`coordinatorITerm2`) run right before each bury of the coordinator's goes out,
  /// for this run's own launch tabs only. When step 7 armed it (`raceArm`), it first waits
  /// until the tab is `earlyDetachAge` old. Then it notes where iTerm2 lists the tab
  /// (`preBuryPlaces`: already buried means iTerm2's auto-hide setting buried it once its
  /// first tmux tab opened, S6). Armed, it then starts the bound `detach-client` in a task of
  /// its own (`startRaceDetach`) and returns at once, so the bury goes out together with the
  /// detach, neither waiting for the other's answer: the tab is buried while tmux ends and the
  /// helper restores it. Every wait is bounded (the age, the detach's wait for the bury, and
  /// the client's own request timeouts).
  private func beforeCoordinatorBury(sessionID: String, connectionID: String) async {
    guard recorder.isLaunchTab(sessionID) else { return }
    guard var armed = raceArm, armed.gateway == nil else {
      preBuryPlaces.updateValue(try? await place(of: sessionID), forKey: sessionID)
      return
    }
    armed.gateway = sessionID
    raceArm = armed
    if let openedAt = recorder.launchedAt(sessionID) {
      let remaining = openedAt + Self.earlyDetachAge - ContinuousClock.now
      if remaining > .zero { try? await Task.sleep(for: remaining) }
    }
    preBuryPlaces.updateValue(try? await place(of: sessionID), forKey: sessionID)
    armed.age = recorder.age(of: sessionID)
    armed.detach = Self.startRaceDetach(
      client: client, recording: coordinatorITerm2, connectionID: connectionID,
      gateway: sessionID, afterBury: armed.lead == .buryFirst)
    raceArm = armed
  } // End of func beforeCoordinatorBury(sessionID:connectionID:)

  /// Step 7's detach, in a task of its own so the hook need not wait for it: a `detach-client`
  /// bound to `gateway` from the harness's own client. With `afterBury`, it goes out only once
  /// the recorder forwarded the bury of `gateway` to the client (polled every millisecond, at
  /// most `raceBuryWait`), never waiting for the bury's answer. Returns when it went out and
  /// when iTerm2 answered, or why it failed.
  private nonisolated static func startRaceDetach(
    client: ITerm2APIClient,
    recording: RecordingITerm2Integration,
    connectionID: String,
    gateway: String,
    afterBury: Bool
  ) -> Task<DetachAnswer, Never> {
    Task.detached {
      if afterBury {
        let deadline = ContinuousClock.now + raceBuryWait
        while ContinuousClock.now < deadline {
          let forwarded = await recording.requests.contains(.buryLaunchTab(sessionID: gateway))
          if forwarded { break }
          try? await Task.sleep(for: .milliseconds(1))
        }
      }
      let sentAt = Date()
      do {
        _ = try await client.sendTmuxCommand(
          ConnectionIdentity.detachCommand, connectionID: connectionID, ownedBy: gateway)
        return DetachAnswer(sentAt: sentAt, answeredAt: Date(), failure: nil)
      } catch let error as ITerm2Error {
        return DetachAnswer(sentAt: sentAt, answeredAt: nil, failure: error.kind)
      } catch {
        return DetachAnswer(sentAt: sentAt, answeredAt: nil, failure: "\(error)")
      }
    }
  } // End of static func startRaceDetach(client:recording:connectionID:gateway:afterBury:)

  /// Step 1: the session, one pane running `sleep 600`.
  private func createSession() async throws -> String {
    creationStartedAt = Int64(Date().timeIntervalSince1970)
    let made = try await tmux.run([
      "new-session", "-d", "-P", "-F", CreatedSession.format, "-s", sessionName, "sleep", "600",
    ])
    guard made.succeeded, made.lines.count == 1, let record = CreatedSession.parse(made.lines[0]),
      record.name == sessionName
    else {
      created = await recoverCreatedSession()
      throw StepFailure("new-session failed: \(made.standardError.prefix(200))")
    }
    created = record
    return "\(record.sessionID) created, its pane running sleep 600"
  } // End of func createSession()

  /// The session step 1 tried to create, found by its exact generated name among the sessions
  /// created since `new-session` started (margins as in `e2e-local`), or `nil`.
  private func recoverCreatedSession() async -> CreatedSession? {
    guard let started = creationStartedAt,
      let listing = try? await tmux.run(["list-sessions", "-F", CreatedSession.format]),
      listing.succeeded
    else { return nil }
    let margin: Int64 = tmux.isLocal ? 2 : 120
    return CreatedSession.find(
      named: sessionName, createdNoEarlierThan: started - margin, in: listing.lines)
  } // End of func recoverCreatedSession()

  /// Step 2: discovery lists the session exactly as created.
  private func discoverSession() async throws -> String {
    guard let created else { throw StepFailure("no test session") }
    let result = try await discovery.discover(host)
    guard case .ok(let sessions) = result.status else {
      throw StepFailure("discovery reported \(result.status.kind)")
    }
    guard let session = sessions.first(where: { $0.key.sessionID == created.sessionID }),
      created.matches(session)
    else { throw StepFailure("discovery did not report the created session as it was") }
    target = AttachTarget(host: host, session: session)
    return "\(created.sessionID) found as created (\(milliseconds(result.duration)) ms)"
  } // End of func discoverSession()

  /// Steps 3, 5, 8 and 10: attaches the session through a new launch tab (with the helper's
  /// `Disinter` suppressed when asked), requires it confirmed with its first tab activated and
  /// the launch tab buried by the coordinator (`checkBuried`), and waits for the helper's
  /// digest to record its attach child's process id.
  private func attachStep(suppressingDisinter: Bool = false) async throws -> String {
    guard let target else { throw StepFailure("no target from discovery") }
    requests.setSuppressesDisinter(suppressingDisinter)
    let result = await coordinator.attach(target)
    requests.setSuppressesDisinter(false)
    launchIDs.append(result.launchID)
    guard result.isConfirmed, let connectionID = result.connectionID,
      let gateway = result.gatewaySessionID
    else {
      throw StepFailure(
        "attach ended \(result.state.kind): \(result.failure?.kind ?? "?") "
          + "\(result.failure?.detail ?? "")")
    }
    guard case .activated(let tabID) = result.activation else {
      throw StepFailure("the first tab was not activated: \(String(describing: result.activation))")
    }
    let buried = try await checkBuried(result, gateway: gateway)
    let digest = try await waitForDigest(result.launchID) { $0.attachChildProcessID != nil }
    guard let digest, let childPID = digest.attachChildProcessID else {
      throw StepFailure("the helper's argv digest recorded no attach child process id within 5 s")
    }
    let expected = [helperPath.path, "attach", result.launchID.rawValue].map {
      LaunchArgvDigest.Argument(bytes: Array($0.utf8))
    }
    guard digest.argumentCount == 3, digest.arguments == expected else {
      throw StepFailure(
        "the helper got \(digest.argumentCount) arguments, not <helper> attach <id>")
    }
    current = Attachment(
      launchID: result.launchID, gateway: gateway, connectionID: connectionID, digest: digest)
    note(
      "confirmed in \(ms(result.timings.confirmed)) ms; helper pid \(digest.helperPID), attach "
        + "child pid \(childPID)"
        + (suppressingDisinter ? "; the request carries testSuppressDisinter" : ""))
    note(buried)
    observePreBury(gateway)
    return "confirmed on connection \(connectionID), tab \(tabID) activated, launch tab \(gateway) "
      + "buried by the coordinator"
  } // End of func attachStep(suppressingDisinter:)

  /// After a confirmed attach (PLAN.md D29): the coordinator buried the launch tab
  /// (`AttachResult.burial` is `buried`), and iTerm2 lists it in `buried_sessions` and in no
  /// tab within `buryListing`. Returns a note for the step.
  private func checkBuried(_ result: AttachResult, gateway: String) async throws -> String {
    guard result.burial == .buried else {
      throw StepFailure(
        "the coordinator did not bury the launch tab: \(result.burial?.kind ?? "no outcome") "
          + "(\(result.burial?.detail ?? "-"))")
    }
    let listed = try await waitForPlace(gateway, in: [.buried], within: Self.buryListing)
    guard let elapsed = listed.elapsed else {
      throw StepFailure(
        "\(Self.buryListing) after the attach the launch tab is listed \(listed.last.rawValue), "
          + "not only in buried_sessions")
    }
    return "burial buried; the launch tab is in buried_sessions and in no tab (the bury and its "
      + "check ended \(ms(result.timings.buried)) ms after the call; listed so "
      + "\(milliseconds(elapsed)) ms after the attach returned)"
  } // End of func checkBuried(_:gateway:)

  /// Observes where iTerm2 listed `gateway` right before the coordinator's bury went out (the
  /// hook's look): already buried means iTerm2's own auto-hide setting buried it once its first
  /// tmux tab opened (S6), so the coordinator's bury answered `OK` on a buried tab (S2).
  private func observePreBury(_ gateway: String) {
    switch preBuryPlaces[gateway] {
    case .buried??:
      observe(
        "iTerm2 had buried the launch tab itself before the coordinator's bury went out (S6: its "
          + "\"Automatically bury the tmux client session\" setting is on); the bury answered OK "
          + "on a buried tab (S2)")
    case .inTab??:
      observe(
        "the launch tab was in its tab when the coordinator's bury went out (iTerm2's auto-hide "
          + "setting is off, or had not acted yet)")
    case .absent??:
      observe("the launch tab was not listed when the coordinator's bury went out")
    case .some(nil):
      observe("the look before the coordinator's bury failed (ListSessions)")
    case nil:
      observe("the coordinator's bury of this launch tab never went out through the hook")
    }
  } // End of func observePreBury(_:)

  /// Takes the argv digests from the launch directory into `digests` (each file holds the
  /// helper's whole digest so far) and returns `launchID`'s.
  private func refreshDigest(_ launchID: LaunchToken) -> LaunchArgvDigest? {
    if let taken = try? store.takeArgvDigests() {
      for digest in taken {
        guard let id = digest.launchID else { continue }
        digests[id] = digest
      }
    }
    return digests[launchID]
  } // End of func refreshDigest(_:)

  /// Polls `launchID`'s digest until `condition` holds or `limit` passes; returns the latest
  /// digest that met it, or `nil`.
  private func waitForDigest(
    _ launchID: LaunchToken,
    within limit: Duration = .seconds(5),
    until condition: (LaunchArgvDigest) -> Bool
  ) async throws -> LaunchArgvDigest? {
    let deadline = ContinuousClock.now + limit
    while true {
      if let digest = refreshDigest(launchID), condition(digest) { return digest }
      guard ContinuousClock.now < deadline else { return nil }
      try await Task.sleep(for: Self.pollInterval)
    }
  } // End of func waitForDigest(_:within:until:)

  /// Where iTerm2 lists `gateway` now.
  private func place(of gateway: String) async throws -> GatewayPlace {
    GatewayPlace(of: gateway, in: try await client.listSessions())
  }

  /// Polls until `gateway` is listed at one of `places` or `limit` passes; returns how long it
  /// took, or `nil` (then `last` says where it was).
  private func waitForPlace(
    _ gateway: String,
    in places: Set<GatewayPlace>,
    within limit: Duration
  ) async throws -> (elapsed: Duration?, last: GatewayPlace) {
    let start = ContinuousClock.now
    while true {
      let now = try await place(of: gateway)
      if places.contains(now) { return (ContinuousClock.now - start, now) }
      guard ContinuousClock.now - start < limit else { return (nil, now) }
      try await Task.sleep(for: Self.pollInterval)
    }
  } // End of func waitForPlace(_:in:within:)

  /// Waits until `attachment`'s launch tab is `age` old.
  private func waitUntilAge(_ attachment: Attachment, _ age: Duration) async throws {
    guard let openedAt = recorder.launchedAt(attachment.gateway) else { return }
    let remaining = openedAt + age - ContinuousClock.now
    if remaining > .zero { try await Task.sleep(for: remaining) }
  }

  /// Sends `detach-client` to `attachment`'s connection, bound to its launch tab, from the
  /// harness itself, as a detach inside the session or by another client ends it (not through
  /// the coordinator, which waits until the tab is 10 s old). A buried launch tab still owns its
  /// connection (spike (a)), so a refusal fails the step; the tab is never restored for it.
  private func boundDetach(_ attachment: Attachment) async throws {
    do {
      _ = try await client.sendTmuxCommand(
        ConnectionIdentity.detachCommand, connectionID: attachment.connectionID,
        ownedBy: attachment.gateway)
    } catch ITerm2Error.tmuxConnectionNotOwned {
      throw StepFailure(
        "the bound detach was refused: iTerm2 no longer lists the launch tab as the connection's "
          + "owner")
    }
  } // End of func boundDetach(_:)

  /// Waits until the connection `connectionID` owned by `gateway` is gone (10 s) and the
  /// helper's result of `launchID` is there (15 s). The result is peeked, never taken, so the
  /// coordinator's watch of the buried tab sees it, as in the app; cleanup takes it. Throws
  /// when the connection stays.
  private func waitForEnd(
    launchID: LaunchToken,
    connectionID: String,
    gateway: String
  ) async throws -> LaunchResult? {
    let closed = try await poll(timeout: .seconds(10)) { () -> Bool? in
      let open = try await self.client.listTmuxConnections().contains {
        $0.connectionID == connectionID && $0.owningSessionID == gateway
      }
      return open ? nil : true
    }
    guard closed == true else {
      throw StepFailure("the connection stayed open after detach-client")
    }
    return try await poll(timeout: .seconds(15)) { () -> LaunchResult? in
      try self.store.peekResult(launchID)
    }
  } // End of func waitForEnd(launchID:connectionID:gateway:)

  /// `waitForEnd(launchID:connectionID:gateway:)` for `attachment`.
  private func waitForEnd(_ attachment: Attachment) async throws -> LaunchResult? {
    try await waitForEnd(
      launchID: attachment.launchID, connectionID: attachment.connectionID,
      gateway: attachment.gateway)
  }

  /// The helper's result after a clean detach: present and exit 0, else the step fails.
  private func requireClean(_ result: LaunchResult?) throws -> LaunchResult {
    guard let result else {
      throw StepFailure("no helper result arrived within 15 s of the connection's end")
    }
    guard result.succeeded else {
      throw StepFailure(
        "the helper's result: exit \(result.exitStatus), \(result.failure?.kind ?? "no failure")")
    }
    return result
  } // End of func requireClean(_:)

  /// Observes `restores` (a helper's digest records): per stage, whether `Disinter` was
  /// written and how the status report ended.
  private func observeRestores(_ restores: [LaunchArgvDigest.TabRestoreRecord]) {
    guard !restores.isEmpty else {
      observe("the helper's digest records no restore")
      return
    }
    for restore in restores {
      let answer = restore.answeredAfterMilliseconds.map { " after \($0) ms" } ?? ""
      let disinter = restore.wroteDisinter ? "written" : "not written"
      observe(
        "restore \(restore.stage.rawValue): Disinter \(disinter), status report "
          + "\(restore.outcome)\(answer)")
    }
  } // End of func observeRestores(_:)

  /// The restores `launchID`'s digest records once one of `stage` is among them (waiting up to
  /// `limit`), or every restore recorded so far.
  private func restores(
    of launchID: LaunchToken,
    through stage: LaunchArgvDigest.TabRestoreRecord.Stage,
    within limit: Duration
  ) async throws -> [LaunchArgvDigest.TabRestoreRecord] {
    let digest = try await waitForDigest(launchID, within: limit) {
      $0.tabRestores?.contains { $0.stage == stage } == true
    }
    return (digest ?? digests[launchID])?.tabRestores ?? []
  } // End of func restores(of:through:within:)

  /// Checks that the test session still exists as created, waiting up to 10 s for it to have
  /// no client; returns its client count. A client still attached then fails the step only
  /// with `requiringNoClient` (after a clean detach); otherwise it is reported (after a kill,
  /// a remote client may take a while to notice its connection is gone).
  private func sessionSurvives(requiringNoClient: Bool = true) async throws -> String {
    guard let created else { throw StepFailure("no test session") }
    var last: [String]?
    let start = ContinuousClock.now
    while true {
      let info = try await tmux.run([
        "display-message", "-p", "-t", created.sessionID.rawValue,
        "#{session_attached}\t" + CreatedSession.format,
      ])
      let fields = info.lines.first?.split(
        separator: "\t", maxSplits: 1, omittingEmptySubsequences: false
      ).map(String.init)
      if info.succeeded, info.lines.count == 1, let fields, fields.count == 2 { last = fields }
      if last?[0] == "0" || ContinuousClock.now - start >= .seconds(10) { break }
      try await Task.sleep(for: Self.pollInterval)
    } // End of loop waiting for the session to have no client
    guard let last, CreatedSession.parse(last[1]) == created else {
      throw StepFailure("the test session did not survive as created")
    }
    if last[0] != "0", requiringNoClient {
      throw StepFailure("a client stayed attached to the test session (\(last[0]))")
    }
    return "the session survived with \(last[0]) client(s)"
  } // End of func sessionSurvives(requiringNoClient:)

  /// Step 4: a detach within 10 s of the attach. At `earlyDetachAge`, a bound `detach-client`
  /// from the harness (`boundDetach`); the connection closes and the helper exits 0; the buried
  /// launch tab must then leave both iTerm2's tabs and `buried_sessions` by itself
  /// (`checkLaunchTabLeft`: the helper restores it, holds until its 10 s minimum lifetime, and
  /// exits, and the tab closes) before any cleanup; the session survives with no client.
  private func detachEarly() async throws -> String {
    guard let attachment = current else { throw StepFailure("no attachment") }
    try await waitUntilAge(attachment, Self.earlyDetachAge)
    let age = recorder.age(of: attachment.gateway)
    try await boundDetach(attachment)
    let result = try requireClean(try await waitForEnd(attachment))
    let left = try await checkLaunchTabLeft(
      attachment.gateway, client: client, recording: coordinatorITerm2,
      within: Self.strandedGatewayWait)
    current = nil
    observeRestores(
      try await restores(of: attachment.launchID, through: .beforeExit, within: .seconds(3)))
    let survived = try await sessionSurvives()
    return "detached at \(age) s by a bound detach-client of the harness; the helper exited "
      + "\(result.exitStatus); the launch tab left its tab and buried_sessions by itself "
      + "\(milliseconds(left)) ms after the helper's result; \(survived)"
  } // End of func detachEarly()

  /// Step 6: a detach after 10 s, through the coordinator
  /// (`detach(connectionID:gatewaySessionID:launchID:)`, as Detach in the app): it waits until
  /// the launch tab is 10 s old, sends `detach-client` bound to it and takes the helper's
  /// result; the connection closes, the helper exits 0, the tmux tabs close, and the buried
  /// launch tab leaves both iTerm2's tabs and `buried_sessions` by itself; the session
  /// survives with no client.
  private func detachThroughCoordinator() async throws -> String {
    guard let attachment = current else { throw StepFailure("no attachment") }
    let detach = await coordinator.detach(
      connectionID: attachment.connectionID, gatewaySessionID: attachment.gateway,
      launchID: attachment.launchID)
    let age = recorder.age(of: attachment.gateway)
    guard detach.commandError != .tmuxConnectionNotOwned else {
      throw StepFailure("the connection is no longer the launch tab's; nothing sent")
    }
    guard detach.connectionClosed else {
      throw StepFailure(
        "connection still open after detach-client (\(detach.commandError?.kind ?? "answered"))")
    }
    guard detach.isClean else {
      throw StepFailure(
        "helper result: \(detach.helperResult.map { "exit \($0.exitStatus)" } ?? "none")")
    }
    let tabsGone = try await poll(timeout: .seconds(5)) { () -> Bool? in
      try await self.client.listSessions().tabs(ofTmuxConnection: attachment.connectionID)
        .isEmpty ? true : nil
    }
    guard tabsGone == true else { throw StepFailure("tmux tabs still open after the detach") }
    let left = try await checkLaunchTabLeft(
      attachment.gateway, client: client, recording: coordinatorITerm2,
      within: Self.strandedGatewayWait)
    current = nil
    observeRestores(
      try await restores(of: attachment.launchID, through: .beforeExit, within: .seconds(3)))
    let survived = try await sessionSurvives()
    return "the coordinator detached it at \(age) s (it waits until the tab is 10 s old); the "
      + "helper exited 0 and the tmux tabs closed; the launch tab left its tab and "
      + "buried_sessions by itself \(milliseconds(left)) ms after the helper's result; "
      + survived
  } // End of func detachThroughCoordinator()

  /// Step 7: D29's race for real, at most `raceAttempts` attaches (`raceAttempt(_:lead:)`):
  /// attempt 1 releases the detach and the bury together, later ones the bury first. An attempt
  /// whose bury its ownership check refused is reported and, once its tab left by itself, the
  /// step races again; on the last attempt it fails (`BuryRaceOutcome.next(afterAttempt:of:)`).
  private func detachAtBuryStep() async throws -> String {
    for attempt in 1...Self.raceAttempts {
      let lead: RaceLead = attempt == 1 ? .together : .buryFirst
      let run = try await raceAttempt(attempt, lead: lead)
      switch run.outcome.next(afterAttempt: attempt, of: Self.raceAttempts) {
      case .pass:
        return "attempt \(attempt) of \(Self.raceAttempts) (\(lead.rawValue)): \(run.detail)"
      case .retry:
        observe(
          "attempt \(attempt): not the race (the bury was refused); its tab left by itself, so "
            + "the step attaches and races again with the bury first")
      case .fail(let reason):
        throw StepFailure("attempt \(attempt) (\(lead.rawValue)): \(reason)")
      }
    } // End of loop over the race's attempts
    throw StepFailure("no attempt ran")
  } // End of func detachAtBuryStep()

  /// One attempt of step 7, the hook armed with `lead` (see `beforeCoordinatorBury`). The attach
  /// must be confirmed with its first tab activated and the hook must have released its bury
  /// and detach; the detach must be answered. The bury's answer and the burial are judged
  /// (`BuryRaceOutcome`): an unexpected outcome returns at once (the step fails); otherwise the
  /// connection must close, the helper exit 0, the launch tab leave both iTerm2's tabs and
  /// `buried_sessions` by itself, and the session survive with no client, the coordinator's
  /// restores recorded by the time the attach returned (its check right after the bury,
  /// `restoredAfterEnd`) allowed, no later one and no `Close`. The order of the detach, the
  /// bury, their answers, the helper's result and first restore and the attach's return is
  /// observed.
  private func raceAttempt(_ attempt: Int, lead: RaceLead) async throws -> RaceAttempt {
    guard let target else { throw StepFailure("no target from discovery") }
    raceArm = RaceArm(lead: lead)
    let result = await coordinator.attach(target)
    let returnedAt = Date()
    let armed = raceArm
    raceArm = nil
    launchIDs.append(result.launchID)
    guard result.isConfirmed, let connectionID = result.connectionID,
      let gateway = result.gatewaySessionID
    else {
      throw StepFailure(
        "attempt \(attempt): attach ended \(result.state.kind): \(result.failure?.kind ?? "?") "
          + "\(result.failure?.detail ?? "")")
    }
    let restoredByReturn = await coordinatorRestores(of: gateway)
    guard case .activated = result.activation else {
      throw StepFailure(
        "attempt \(attempt): the first tab was not activated: "
          + String(describing: result.activation))
    }
    guard let armed, armed.gateway == gateway, let detachTask = armed.detach else {
      throw StepFailure(
        "attempt \(attempt): the coordinator's bury of this launch tab never went out through "
          + "the hook, so nothing raced it (burial \(result.burial?.kind ?? "none"))")
    }
    let detach = await detachTask.value
    if let failure = detach.failure {
      throw StepFailure("attempt \(attempt): the detach released with the bury failed: \(failure)")
    }
    let answers = await coordinatorITerm2.buryAnswers(of: gateway)
    let outcome = BuryRaceOutcome(burial: result.burial, answers: answers)
    observePreBury(gateway)
    note(
      "attempt \(attempt) (\(lead.rawValue)), released when the tab was \(armed.age ?? "?") s "
        + "old; the coordinator had sent \(restoredByReturn) restore(s) of the tab by the time "
        + "the attach returned")
    if case .unexpected = outcome { return RaceAttempt(outcome: outcome, detail: "") }
    observeRace(outcome, attempt: attempt)
    let ended = try requireClean(
      try await waitForEnd(launchID: result.launchID, connectionID: connectionID, gateway: gateway)
    )
    let first = try await restores(of: result.launchID, through: .afterChild, within: .seconds(5))
      .first { $0.stage == .afterChild }
    var events: [(String, Date)] = [
      ("detach sent", detach.sentAt), ("attach returned", returnedAt),
    ]
    if let answeredAt = detach.answeredAt { events.append(("detach answered", answeredAt)) }
    if let bury = answers.first {
      events += [("bury forwarded", bury.forwardedAt), ("bury answered", bury.answeredAt)]
    }
    events.append(("helper's result", ended.endedAt))
    if let first {
      events += [
        ("first restore requested", first.requestedAt), ("first restore ended", first.endedAt),
      ]
    }
    observe("attempt \(attempt) order: \(Self.timeline(events))")
    let left = try await checkLaunchTabLeft(
      gateway, client: client, recording: coordinatorITerm2, within: Self.strandedGatewayWait,
      allowedRestores: restoredByReturn)
    observeRestores(
      try await restores(of: result.launchID, through: .beforeExit, within: .seconds(3)))
    let survived = try await sessionSurvives()
    let bury = outcome == .refused ? "the bury was refused" : "the bury was sent and answered OK"
    let detail =
      "\(bury), burial \(result.burial?.kind ?? "-"); the helper exited 0; the launch tab left "
      + "its tab and buried_sessions by itself "
      + "\(milliseconds(left)) ms after the helper's result; \(survived)"
    return RaceAttempt(outcome: outcome, detail: detail)
  } // End of func raceAttempt(_:lead:)

  /// `events` sorted by time, each in milliseconds after the first: one line for the step.
  static func timeline(_ events: [(String, Date)]) -> String {
    let sorted = events.sorted { $0.1 < $1.1 }
    guard let start = sorted.first?.1 else { return "nothing recorded" }
    return sorted.map { "\($0.0) +\(milliseconds(from: start, to: $0.1)) ms" }
      .joined(separator: ", ")
  }

  /// How many restores of `gateway` the coordinator has sent so far (each recorded before it
  /// was sent).
  private func coordinatorRestores(of gateway: String) async -> Int {
    await coordinatorITerm2.restoresAndCloses(of: gateway).filter {
      if case .setBuried = $0 { true } else { false }
    }.count
  }

  /// Observes the judgement of one of step 7's attempts (`unexpected` fails the step, so it is
  /// never observed here).
  private func observeRace(_ outcome: BuryRaceOutcome, attempt: Int) {
    switch outcome {
    case .raced(.buried):
      observe(
        "attempt \(attempt): burial buried: the bury was sent and answered OK while tmux still "
          + "ran (the coordinator's check after it saw no result and the connection still "
          + "owned); the helper's restore at the tmux end undoes it")
    case .raced(let burial):
      observe(
        "attempt \(attempt): burial \(burial.kind): the bury was sent and answered OK, and the "
          + "coordinator's check after it saw that tmux had ended and restored the tab at once "
          + "(PLAN.md D29, the race closed by order)")
    case .refused:
      observe(
        "attempt \(attempt): burial failed (tmuxConnectionNotOwned): the bury's ownership check "
          + "found the connection gone, so nothing was buried and the race did not run; not "
          + "counted")
    case .unexpected(let reason):
      observe("attempt \(attempt): \(reason)")
    }
  } // End of func observeRace(_:attempt:)

  /// Step 9 (b, d): the coordinator's recovery of a dead buried tab (PLAN.md D29, design item
  /// 5), with the helper's `Disinter` suppressed (step 8's request). At `earlyDetachAge`, a
  /// bound detach; once the helper's first restore ran, where the tab is tells iTerm2's
  /// auto-hide setting without reading it (S5). In a tab, iTerm2 restored it itself (the
  /// setting is on): the tab must leave by itself, as in step 4. Buried, the setting is off: the
  /// tab stays buried, is a dead buried session once its helper exits (S4), and the
  /// coordinator's recovery must remove it (a restore, then a forced `Close` of its own session
  /// id, spike (d)) within `recoveryWait` of the helper's result, or the step fails.
  private func deadTabRecovery() async throws -> String {
    guard let attachment = current else { throw StepFailure("no attachment") }
    try await waitUntilAge(attachment, Self.earlyDetachAge)
    try await boundDetach(attachment)
    _ = try requireClean(try await waitForEnd(attachment))
    let resultSeenAt = ContinuousClock.now
    _ = try await restores(of: attachment.launchID, through: .afterChild, within: .seconds(5))
    let afterEnd = try await place(of: attachment.gateway)
    current = nil
    guard afterEnd == .buried else {
      if afterEnd == .inTab {
        restoredAtEndWithoutDisinter = true
        observe(
          "after the tmux end the launch tab is in a tab although the helper wrote no Disinter: "
            + "iTerm2 restored it itself (S5: its auto-hide setting is on), so no dead tab is "
            + "left for the coordinator to recover")
      } else {
        observe("the launch tab was already gone right after the tmux end")
      }
      let left = try await checkLaunchTabLeft(
        attachment.gateway, client: client, recording: coordinatorITerm2,
        within: Self.strandedGatewayWait)
      observeRestores(
        try await restores(of: attachment.launchID, through: .beforeExit, within: .seconds(3)))
      let survived = try await sessionSurvives()
      let how =
        afterEnd == .inTab
        ? "iTerm2 restored the launch tab at the tmux end (its auto-hide setting is on)"
        : "the launch tab was gone right after the tmux end"
      return "\(how); it left its tab and buried_sessions by itself \(milliseconds(left)) ms "
        + "later; \(survived)"
    }
    restoredAtEndWithoutDisinter = false
    observe(
      "after the tmux end the launch tab stayed buried with no Disinter: iTerm2's auto-hide "
        + "setting is off (S5)")
    let removed = try await awaitRecovery(attachment, since: resultSeenAt)
    let survived = try await sessionSurvives()
    return "\(removed); \(survived)"
  } // End of func deadTabRecovery()

  /// Step 9 with the setting off: waits for the helper to exit (20 s), observes the dead buried
  /// session (S4), then waits until `recoveryWait` after `resultSeenAt` for the launch tab to be
  /// gone, and reads the coordinator's recorded restores and `Close`s of it. Returns the step's
  /// detail; a tab still listed then fails the step.
  private func awaitRecovery(
    _ attachment: Attachment,
    since resultSeenAt: ContinuousClock.Instant
  ) async throws -> String {
    let helper = attachment.digest.helperPID
    let exited = try await poll(timeout: .seconds(20)) { () -> Bool? in
      ProcessCheck.isAlive(helper) ? nil : true
    }
    observe(exited == true ? "the helper exited" : "the helper still runs 20 s after its result")
    if try await place(of: attachment.gateway) == .buried {
      observe("a dead buried session remained after its helper exited (S4)")
    }
    let remaining = resultSeenAt + Self.recoveryWait - ContinuousClock.now
    let gone = try await poll(timeout: max(remaining, .zero)) { () -> Bool? in
      try await self.client.listSessions().allSessionIDs.contains(attachment.gateway)
        ? nil : true
    }
    let touched = await coordinatorITerm2.restoresAndCloses(of: attachment.gateway).count
    let restores = await coordinatorRestores(of: attachment.gateway)
    let closes = touched - restores
    guard gone == true else {
      let place = try await place(of: attachment.gateway)
      throw StepFailure(
        "the dead launch tab is still listed \(place.rawValue) \(Self.recoveryWait) after its "
          + "helper's result: the coordinator's recovery did not remove it (\(restores) "
          + "restore(s), \(closes) Close(s) sent)")
    }
    observeRestores(refreshDigest(attachment.launchID)?.tabRestores ?? [])
    guard closes > 0 else {
      observe("the dead tab left without a restore or Close of the coordinator's (unlike S4)")
      return "the launch tab left by itself"
    }
    observe(
      "the coordinator's recovery sent \(restores) restore(s) and \(closes) forced Close(s) of "
        + "the dead buried tab, and it is gone")
    return "the coordinator's recovery removed the dead buried launch tab within "
      + "\(Self.recoveryWait) of its helper's result"
  } // End of func awaitRecovery(_:since:)

  /// Step 11 (e): SIGKILL of only the helper's attach child while the coordinator's bury
  /// holds, then `watchKilledTab(_:killedAt:)` and
  /// `checkKillTimeline(_:attachment:killedAt:)`.
  private func killAttachChild() async throws -> String {
    guard let attachment = current, let childPID = attachment.digest.attachChildProcessID else {
      throw StepFailure("no attachment with a recorded attach child")
    }
    if case .remote = kind, sharing != .off {
      observe(
        "not killed: ssh -G shows connection sharing \(sharing) for the destination, so the local "
          + "ssh child may carry other sessions; the attachment is detached in step 12")
      return "skipped (ssh connection sharing \(sharing))"
    }
    let expected: String
    switch kind {
    case .local:
      guard let local = tmux as? TestTmux else { throw StepFailure("no local tmux path") }
      expected = local.path
    case .remote:
      expected = RemoteLaunch.sshPath
    }
    let expectedChild = LaunchArgvDigest.Argument(bytes: Array(expected.utf8))
    guard attachment.digest.attachChild?.arguments.first == expectedChild else {
      throw StepFailure("the helper's attach child is not \(expected); not touching it")
    }
    let before = try await place(of: attachment.gateway)
    guard before == .buried else {
      throw StepFailure("the launch tab is listed \(before.rawValue) before the kill, not buried")
    }
    guard ProcessCheck.parent(of: childPID) == attachment.digest.helperPID,
      ProcessCheck.executablePath(of: childPID) == ProcessCheck.resolved(expected)
    else {
      throw StepFailure(
        "process \(childPID) is not the helper's attach child running \(expected); not touching it")
    }
    let killedAt = Date()
    guard kill(childPID, SIGKILL) == 0 else {
      throw StepFailure("kill(\(childPID), SIGKILL) failed (errno \(errno))")
    }
    killed = true
    killedGateways.insert(attachment.gateway)
    observe("SIGKILL sent to the attach child \(childPID) (\(expected)), nothing else")
    let seen = try await watchKilledTab(attachment, killedAt: killedAt)
    killTimeline = seen
    let back = try await checkKillTimeline(seen, attachment: attachment, killedAt: killedAt)
    let survived = try await sessionSurvives(requiringNoClient: false)
    return "the attach child was killed while buried; \(back); \(survived)"
  } // End of func killAttachChild()

  /// Watches after the kill until `watchEnd(for:killedAt:)` (every `killPollInterval`, every
  /// `settledPollInterval` once the tab is back and the connection and its tmux tabs are gone):
  /// the helper's result (peeked), the connection and its tmux tabs, where the launch tab is at
  /// each look (`KilledLaunchTabWatch`), and how many restores of it the coordinator had sent
  /// when a look first saw it in a tab. Never buries or restores anything.
  private func watchKilledTab(_ attachment: Attachment, killedAt: Date) async throws
    -> KillTimeline
  {
    let start = ContinuousClock.now
    var seen = KillTimeline()
    while true {
      if seen.result == nil { seen.result = try store.peekResult(attachment.launchID) }
      if seen.connectionGone == nil {
        let connections = try await client.listTmuxConnections()
        if !connections.contains(where: {
          $0.connectionID == attachment.connectionID && $0.owningSessionID == attachment.gateway
        }) {
          seen.connectionGone = Date()
        }
      }
      let sessions = try await client.listSessions()
      let lookedAt = Date()
      if seen.tabsGone == nil, sessions.tabs(ofTmuxConnection: attachment.connectionID).isEmpty {
        seen.tabsGone = lookedAt
      }
      let wasBack = seen.watch.firstInTab != nil
      seen.watch.record(GatewayPlace(of: attachment.gateway, in: sessions), at: lookedAt)
      if !wasBack, seen.watch.firstInTab != nil {
        seen.coordinatorRestoresByThen = await coordinatorRestores(of: attachment.gateway)
      }
      guard Date() < watchEnd(for: seen.result, killedAt: killedAt),
        ContinuousClock.now - start < Self.killWatchLimit
      else { break }
      let settled = wasBack && seen.connectionGone != nil && seen.tabsGone != nil
      try await Task.sleep(for: settled ? Self.settledPollInterval : Self.killPollInterval)
    } // End of loop watching after the kill
    return seen
  } // End of func watchKilledTab(_:killedAt:)

  /// When step 11's watch may end: `killWatch` after the kill, or `lifetimeMargin` after the
  /// helper's minimum lifetime ended (from its result's start), whichever is later.
  private func watchEnd(for result: LaunchResult?, killedAt: Date) -> Date {
    let earliest = killedAt.adding(Self.killWatch)
    guard let result else { return earliest }
    let visible = KilledLaunchTabWatch.visibleUntil(
      result, minimumLifetime: LaunchHelper.defaultMinimumLifetime)
    return max(earliest, visible.adding(Self.lifetimeMargin))
  } // End of func watchEnd(for:killedAt:)

  /// Step 11's requirements on the killed attach's tab (`KilledLaunchTabWatch.Facts`): the
  /// helper's restores (an answered status report before its exit), whether it still runs, and
  /// the coordinator's recorded `Close`s and buries that may have touched the tab.
  private func killFacts(
    _ seen: KillTimeline,
    attachment: Attachment,
    restores: [LaunchArgvDigest.TabRestoreRecord],
    helperAlive: Bool
  ) async -> KilledLaunchTabWatch.Facts {
    let gateway = attachment.gateway
    let closes = await coordinatorITerm2.restoresAndCloses(of: gateway).filter {
      if case .close = $0 { true } else { false }
    }.count
    let buries = await coordinatorITerm2.requests.filter {
      $0 == .buryLaunchTab(sessionID: gateway) || $0 == .setBuried(buried: true, sessionID: gateway)
    }.count
    return KilledLaunchTabWatch.Facts(
      result: seen.result,
      answeredStatusReport: restores.contains {
        $0.stage != .beforeExit && $0.outcome == "answered"
      },
      helperAlive: helperAlive, coordinatorCloses: closes, coordinatorBuries: buries)
  } // End of func killFacts(_:attachment:restores:helperAlive:)

  /// Observes what `watchKilledTab(_:killedAt:)` saw, with the helper's restores, its result and
  /// whether it still runs, and judges it (`KilledLaunchTabWatch.verdict(_:)`): the result
  /// `childSignaled(9)`, exit 137; the tab back in a tab and still there at every later look
  /// until past the helper's minimum lifetime; an answered status report of the helper's
  /// (iTerm2 parses the tab as a terminal again, so the explanation written next is drawn); no
  /// `Close` and no further bury of the coordinator's; the helper alive. Returns who brought
  /// the tab back and when.
  private func checkKillTimeline(
    _ seen: KillTimeline,
    attachment: Attachment,
    killedAt: Date
  ) async throws -> String {
    let since = { (date: Date) in "\(milliseconds(from: killedAt, to: date)) ms" }
    let watched = seen.watch.last.map { "\(since($0.at)) after the kill" } ?? "the watch"
    observe(
      "the tmux connection "
        + (seen.connectionGone.map { "left ListConnections \(since($0)) after the kill" }
          ?? "is still listed \(watched)"))
    observe(
      "its tmux tabs "
        + (seen.tabsGone.map { "were gone \(since($0)) after the kill" }
          ?? "are still listed \(watched)"))
    let restores = refreshDigest(attachment.launchID)?.tabRestores ?? []
    observeRestores(restores)
    let alive = ProcessCheck.isAlive(attachment.digest.helperPID)
    observe(
      alive
        ? "the helper still runs (after a failure it waits for Return; this run never types it)"
        : "the helper has exited")
    if let result = seen.result {
      observe(
        "the helper's result: exit \(result.exitStatus)"
          + (result.failure.map { ", \($0.kind)" } ?? ", clean")
          + "; its minimum lifetime ended "
          + since(
            KilledLaunchTabWatch.visibleUntil(
              result, minimumLifetime: LaunchHelper.defaultMinimumLifetime))
          + " after the kill")
    }
    let facts = await killFacts(
      seen, attachment: attachment, restores: restores, helperAlive: alive)
    let firstInTab: Date
    switch seen.watch.verdict(facts) {
    case .failed(let reason): throw StepFailure(reason)
    case .passed(let cameBackAt): firstInTab = cameBackAt
    }
    let first = restores.first { $0.stage == .afterChild }
    let who: String
    if seen.coordinatorRestoresByThen > 0 {
      who =
        "possibly by the coordinator's recovery (it had sent a restore after the helper's "
        + "failure result)"
    } else if let first, firstInTab < first.endedAt {
      who =
        "by iTerm2 itself while the helper's first restore still waited (S5: its auto-hide "
        + "setting is on; the line feed ended tmux mode)"
    } else {
      who = "by the helper's restores"
    }
    observe(
      "the launch tab was back in a tab \(since(firstInTab)) after the kill, \(who), and in a "
        + "tab at every look after that until \(watched) (\(seen.watch.lookCount) looks in all)")
    return "the helper's result childSignaled(9), exit 137; the launch tab came back "
      + "\(since(firstInTab)) after the kill with an answered status report (the explanation "
      + "is drawn), \(who), and stayed in its tab, its helper alive, past the helper's minimum "
      + "lifetime (\(watched))"
  } // End of func checkKillTimeline(_:attachment:killedAt:)

  /// Step 12: one more look with step 11's requirements right before the close
  /// (`KilledLaunchTabWatch`: the tab still in a tab, its helper alive, no `Close` or further
  /// bury of the coordinator's); then the killed attach's launch tab (its helper waiting for
  /// Return) closed (forced) where it is listed, restored and closed again if that left it; the
  /// helper must end and no connection of the tab may stay listed. A failed last look fails the
  /// step once the tab is removed. When step 11 skipped the kill, a clean detach through the
  /// coordinator instead, the tab leaving by itself.
  private func closeAfterKill() async throws -> String {
    guard let attachment = current else { throw StepFailure("no attachment") }
    guard killed else {
      let detach = await coordinator.detach(
        connectionID: attachment.connectionID, gatewaySessionID: attachment.gateway,
        launchID: attachment.launchID)
      guard detach.isClean else {
        throw StepFailure(
          "the clean detach ended \(detach.connectionClosed ? "closed" : "open"), helper result "
            + (detach.helperResult.map { "exit \($0.exitStatus)" } ?? "none"))
      }
      let left = try await checkLaunchTabLeft(
        attachment.gateway, client: client, recording: coordinatorITerm2,
        within: Self.strandedGatewayWait)
      current = nil
      return "detached cleanly through the coordinator (nothing was killed); the launch tab left "
        + "by itself \(milliseconds(left)) ms after the helper's result"
    }
    try await waitUntilAge(attachment, Self.minimumTabAge)
    let running = ProcessCheck.isAlive(attachment.digest.helperPID)
    let now = try await place(of: attachment.gateway)
    var lastLook: String?
    if var seen = killTimeline {
      seen.watch.record(now, at: Date())
      let restores = refreshDigest(attachment.launchID)?.tabRestores ?? []
      let facts = await killFacts(
        seen, attachment: attachment, restores: restores, helperAlive: running)
      if case .failed(let reason) = seen.watch.verdict(facts) {
        lastLook = "right before the close: \(reason)"
      }
    }
    var gone = now == .absent
    if gone {
      observe("the launch tab was gone already")
    } else {
      let label = now == .buried ? "buried" : "restored"
      gone = try await closeObserving(
        attachment.gateway, label: label + (running ? " (its helper waiting for Return)" : ""))
    }
    if !gone {
      let ended = await restoreThenClose(attachment.gateway)
      observe("restore, then close: \(ended.details.joined(separator: "; "))")
      guard ended.gone else { throw StepFailure("the launch tab could not be removed") }
    }
    let helper = attachment.digest.helperPID
    let ended = try await poll(timeout: .seconds(10)) { () -> Bool? in
      ProcessCheck.isAlive(helper) ? nil : true
    }
    guard ended == true else { throw StepFailure("the helper still runs 10 s after the close") }
    let released = try await poll(timeout: .seconds(5)) { () -> Bool? in
      let left = try await self.client.listTmuxConnections().contains {
        $0.owningSessionID == attachment.gateway
      }
      return left ? nil : true
    }
    guard released == true else {
      throw StepFailure("a connection owned by the closed launch tab is still listed")
    }
    killedGateways.remove(attachment.gateway)
    current = nil
    let survived = try await sessionSurvives(requiringNoClient: false)
    if let lastLook { throw StepFailure(lastLook) }
    return "right before the close the launch tab was still in a tab with its helper alive; it "
      + "is gone now, its helper ended and no connection is left; \(survived)"
  } // End of func closeAfterKill()

  /// Closes `gateway` (forced) where it is listed now and observes the statuses and whether it
  /// is gone within 5 s. Returns whether it is gone.
  private func closeObserving(_ gateway: String, label: String) async throws -> Bool {
    let response = try await client.close(.init(target: .sessions([gateway]), force: true))
    let gone = try await waitForPlace(gateway, in: [.absent], within: .seconds(5))
    observe(
      "Close of the \(label) session answered \(Self.names(response.statuses)); it is "
        + (gone.elapsed.map { "gone \(milliseconds($0)) ms later" }
          ?? "still listed \(gone.last.rawValue) 5 s later"))
    return gone.elapsed != nil
  } // End of func closeObserving(_:label:)

  /// Restores `gateway` if it is buried, then closes it (forced), checking every status and the
  /// session's absence afterwards. Returns whether it is gone, and what each answer was.
  private func restoreThenClose(_ gateway: String) async -> (gone: Bool, details: [String]) {
    var details: [String] = []
    guard let now = try? await place(of: gateway) else {
      return (false, ["the sessions could not be listed"])
    }
    if now == .absent { return (true, []) }
    if now == .buried {
      do {
        try await client.setBuried(false, sessionID: gateway)
        details.append("the restore answered OK")
      } catch let error as ITerm2Error {
        details.append("the restore failed (\(error.kind))")
      } catch {
        details.append("the restore failed")
      }
      _ = try? await waitForPlace(gateway, in: [.inTab, .absent], within: .seconds(5))
    }
    do {
      let response = try await client.close(.init(target: .sessions([gateway]), force: true))
      details.append("Close answered \(Self.names(response.statuses))")
    } catch let error as ITerm2Error {
      details.append("Close failed (\(error.kind))")
    } catch {
      details.append("Close failed")
    }
    let gone = try? await waitForPlace(gateway, in: [.absent], within: .seconds(5))
    if gone?.elapsed == nil {
      details.append("launch tab \(gateway) is still listed \(gone?.last.rawValue ?? "?")")
    }
    return (gone?.elapsed != nil, details)
  } // End of func restoreThenClose(_:)

  /// Close statuses by their protocol names.
  static func names(_ statuses: [ITerm2API.CloseResponse.Status]) -> String {
    let names = statuses.map { status -> String in
      switch status {
      case .ok: return "OK"
      case .notFound: return "NOT_FOUND"
      case .userDeclined: return "USER_DECLINED"
      case .unknown(let value): return "status \(value)"
      }
    }
    return names.isEmpty ? "no status" : names.joined(separator: ", ")
  } // End of static func names(_:)

  /// What the run saw of iTerm2's "Automatically bury the tmux client session after
  /// connecting" setting, without reading it: step 9's tmux end without `Disinter` decides it
  /// (S5); without it, the looks right before the coordinator's buries (S6) suggest it. `nil`
  /// when nothing was seen.
  private func autoHideSummary() -> String? {
    let looked = preBuryPlaces.values.compactMap { $0 }
    guard !looked.isEmpty || restoredAtEndWithoutDisinter != nil else { return nil }
    let buriedFirst = looked.filter { $0 == .buried }.count
    var seen = [
      "iTerm2 had buried \(buriedFirst) of \(looked.count) launch tab(s) itself before the "
        + "coordinator's bury went out (S6)"
    ]
    let verdict: String
    switch restoredAtEndWithoutDisinter {
    case true?:
      seen.append("restored step 9's launch tab itself at the tmux end without Disinter (S5)")
      verdict = "on"
    case false?:
      seen.append("left step 9's launch tab buried at the tmux end without Disinter (S5)")
      verdict = "off"
    case nil:
      verdict = buriedFirst > 0 ? "on" : "probably off"
    }
    return "iTerm2's \"Automatically bury the tmux client session after connecting\" setting "
      + "looks \(verdict) (never read: \(seen.joined(separator: "; ")))"
  } // End of func autoHideSummary()

  // MARK: - Cleanup

  /// Step 13 (see the type's documentation). Never cancels itself.
  func cleanUp() async {
    let start = ContinuousClock.now
    var actions: [String] = []
    var problems: [String] = []
    var byHand: [String] = []
    await coordinatorITerm2.setBeforeBury(nil)
    raceArm = nil
    let gateways = Set(recorder.gatewaySessionIDs)
    if let latest = recorder.latestLaunch(of: Array(gateways)) {
      let remaining = latest + Self.minimumTabAge - ContinuousClock.now
      if remaining > .zero {
        output("  waiting \(milliseconds(remaining)) ms so no launch tab ends too young")
        try? await Task.sleep(for: remaining)
      }
    }
    let stillOwned = await detachLeftovers(gateways, actions: &actions)
    if stillOwned == nil, !gateways.isEmpty {
      problems.append("iTerm2's tmux connections could not be listed")
    }
    let attached = Set(stillOwned ?? Array(gateways))
    for gateway in gateways.sorted() where !attached.contains(gateway) {
      guard let now = try? await place(of: gateway), now != .absent else { continue }
      let ended = await restoreThenClose(gateway)
      actions.append(
        "launch tab \(gateway) was \(now.rawValue): \(ended.details.joined(separator: ", "))")
      if !ended.gone { problems.append("launch tab \(gateway) could not be removed") }
    } // End of loop over the run's launch tabs
    if !attached.isEmpty {
      problems.append(
        "launch tab(s) \(attached.sorted().joined(separator: ", ")) may still be attached, so they "
          + "were left open and \(sessionName) was not killed")
      byHand.append("clean up by hand (detach, never close the tab), then end the session:")
      byHand.append("swift run muxfinder-probe iterm2 list-connections")
      for gateway in attached.sorted() {
        byHand.append("swift run muxfinder-probe detach --connection <id> --gateway \(gateway)")
      }
      byHand.append("tmux kill-session -t '=\(sessionName)'  (tmux \(tmux.location))")
    } else {
      await killTestSession(actions: &actions, problems: &problems)
    }
    let taken = launchIDs.filter { (try? store.takeResult($0)) != nil }.count
    if taken > 0 { actions.append("took \(taken) helper result(s) nobody took") }
    if markerCreated {
      do throws(LaunchStoreError) {
        _ = try store.takeArgvDigests()
        if try store.removeTestModeMarker() { actions.append("removed the test-mode marker") }
      } catch {
        problems.append("could not remove the test-mode marker")
      }
    }
    if attached.isEmpty { problems += await verifyClean(gateways) }
    await client.disconnect()
    let elapsed = milliseconds(ContinuousClock.now - start)
    let summary = actions.isEmpty ? "nothing to clean" : actions.joined(separator: ", ")
    if problems.isEmpty, setUp {
      passedCount += 1
      output(
        "PASS \(Self.stepCount) cleanup (\(elapsed) ms): \(summary); no test session, launch tab "
          + "(in a tab or buried), connection or marker left")
    } else {
      let reason = problems.isEmpty ? "setup failed" : problems.joined(separator: "; ")
      output("FAIL \(Self.stepCount) cleanup (\(elapsed) ms): \(summary); \(reason)")
    }
    for line in byHand { output("  \(line)") }
    if let summary = autoHideSummary() { output("  OBSERVATION: \(summary)") }
  } // End of func cleanUp()

  /// Kills the test session, the one step 1 recorded or, when a signal cut `new-session`
  /// short, the one found by its exact name, only while it is still exactly that session
  /// (the check in the same tmux command as the kill).
  private func killTestSession(actions: inout [String], problems: inout [String]) async {
    if created == nil, let recovered = await recoverCreatedSession() {
      created = recovered
      actions.append("found the test session by its name")
    }
    guard let created, let arguments = created.killIfUnchangedArguments,
      created.name == sessionName
    else { return }
    let result = try? await tmux.run(arguments)
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

  /// Sends a bound `detach-client` to every connection one of `gateways` owns (never to a
  /// killed attach's, whose client is gone), then lists until none of them owns a connection
  /// (10 s). Returns the launch tabs that still own a live one, or `nil` when the connections
  /// could not be listed.
  private func detachLeftovers(_ gateways: Set<String>, actions: inout [String]) async -> [String]?
  {
    guard !gateways.isEmpty else { return [] }
    var sent: Set<String> = []
    let deadline = ContinuousClock.now + .seconds(10)
    while true {
      guard let listed = try? await client.listTmuxConnections() else { return nil }
      let owned = listed.filter {
        guard let owner = $0.owningSessionID else { return false }
        return gateways.contains(owner) && !killedGateways.contains(owner)
      }
      if owned.isEmpty { return [] }
      for connection in owned {
        guard let id = connection.connectionID, let owner = connection.owningSessionID,
          sent.insert(id + "\u{0}" + owner).inserted
        else { continue }
        _ = try? await client.sendTmuxCommand(
          ConnectionIdentity.detachCommand, connectionID: id, ownedBy: owner)
        actions.append("sent detach-client to a leftover connection")
      } // End of loop over the connections not asked yet
      guard ContinuousClock.now < deadline else {
        return Array(Set(owned.compactMap(\.owningSessionID)))
      }
      try? await Task.sleep(for: Self.pollInterval)
    } // End of loop until no launch tab of the run owns a connection
  } // End of func detachLeftovers(_:actions:)

  /// What is left of the run: the session, any launch tab (in a tab or buried), connections,
  /// the marker.
  private func verifyClean(_ gateways: Set<String>) async -> [String] {
    var problems: [String] = []
    if let names = try? await tmux.run(["list-sessions", "-F", "#{session_name}"]), names.succeeded,
      names.lines.contains(sessionName)
    {
      problems.append("the test session still exists")
    }
    let gone = try? await poll(timeout: .seconds(5)) { () -> Bool? in
      let sessions = try await self.client.listSessions()
      let connections = try await self.client.listTmuxConnections()
      let tabsLeft = gateways.contains { sessions.allSessionIDs.contains($0) }
      let connectionsLeft = connections.contains { gateways.contains($0.owningSessionID ?? "") }
      return tabsLeft || connectionsLeft ? nil : true
    }
    if gone != true { problems.append("a launch tab or connection of this run is still listed") }
    if store.testModeMarkerExists() { problems.append("the test-mode marker is still there") }
    return problems
  } // End of func verifyClean(_:)
} // End of actor E2EBuryRun
