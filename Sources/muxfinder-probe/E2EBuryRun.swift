import AppKit
import Darwin
import Foundation
import MuxFinderCore

/// `muxfinder-probe e2e-bury --local | --ssh <destination>`: the spike of PLAN.md Phase 13a.
/// It learns how iTerm2 3.7.6 treats a launch tab buried through its API, with the 13a
/// helper's restore (`Disinter`, then a status report request) and without it. It changes no
/// coordinator code: the attaches go through an unchanged `AttachCoordinator` (over a request
/// store that can set the helper's test switch), and the bury, the detach and every close
/// through the iTerm2 client directly.
///
/// iTerm2's "Automatically bury the tmux client session after connecting" setting
/// (`AutoHideTmuxClientSession`, off by default) changes what happens: with it on, iTerm2
/// buries each launch tab itself once its first tmux tab opens (S6) and restores it itself when
/// tmux ends (S5). The run never reads or writes that setting; it sees it in what iTerm2 does,
/// and where the setting would hide the default behavior it buries its own launch tab again at
/// the moment the default would have left it buried, so the helper's restores are still seen.
///
/// Steps (each prints one PASS or FAIL line; `OBSERVATION` lines carry what iTerm2 did, since
/// the expected answers are what the spike establishes; FAIL means a harness or safety
/// problem, and the first one stops the run, then cleanup runs):
/// 1. **create session:** `muxfinder-test-<hex>`, one pane running `sleep 600`.
/// 2. **discover:** discovery lists it exactly as created.
/// 3. **attach:** confirmed and its first tab activated; the helper's argv digest records its
///    attach child's process id; whether iTerm2 buries the launch tab itself (S6).
/// 4. **bury (a):** when iTerm2 buried the tab itself, `GetProperty` `buried` and a restore
///    (`SetProperty` `buried` false: where it comes back, S8) first; then `buryLaunchTab`
///    (bound to the launch tab's connection); where the session is listed afterwards
///    (`ListSessions`, `GetProperty` `buried`), its window, its connection's tabs and owner, and
///    a second bury (idempotent, S2).
/// 5. **detach buried (c):** once the tab is `earlyDetachAge` old, a bound `detach-client`
///    while it is buried, sampling `ListSessions` meanwhile: who restored it at the tmux end
///    (iTerm2 itself, or the helper's first restore), then a bury during the helper's hold and
///    its last restore; for each restore of the helper's, whether a sample sent after its
///    status report answer still saw the session buried (the answer before the restore, S7
///    false), and whether anything is left.
/// 6. **attach without Disinter:** a second attach whose request carries the helper's test
///    switch (`testSuppressDisinter`).
/// 7. **detach without Disinter (b):** bury, a bound detach at `earlyDetachAge`, where the tab
///    is after the tmux end (S5), a bury during the hold when it was restored, then whether a
///    dead buried session remains once the helper has exited (S4).
/// 8. **close buried (d):** forced `Close` of that buried session by its id: its status, and
///    whether it is gone; if not, restore, then close (statuses and absence checked).
/// 9. **attach for the kill:** a third attach, the normal helper.
/// 10. **kill attach child (e):** bury, then SIGKILL of only the helper's attach child (the
///    process id its digest recorded, checked to be the helper's child running the expected
///    executable: locally tmux, remotely the local `/usr/bin/ssh`, killed only when `ssh -G`
///    shows no connection sharing); what follows, every 100 ms: the result, the connection
///    and its tabs, where the launch tab is (when iTerm2 restores it itself during the
///    helper's first restore, it is buried again once, so the helper's second restore is
///    seen), the helper's restores (an answer means iTerm2 parses the tab as a terminal again,
///    so the explanation written after it is drawn), whether the helper still waits for Return
///    (Return itself is never pressed: no keystrokes), and whether the session survived.
/// 11. **close after the kill (d):** the killed attach's launch tab, buried again if it is in a
///    tab, then closed (forced) while buried (`Close` of a live buried session), restored and
///    closed if that left it; the helper must end and no connection of the tab may stay
///    listed. When step 10 skipped the kill, a clean bound detach instead.
///
/// **Cleanup** (step 12, on every way out, SIGINT and SIGTERM included): once every launch tab
/// of the run is 10 s old, a bound `detach-client` for each connection one of them owns
/// (never for the killed attach's, whose client is gone), then each launch tab of the run still
/// listed is restored if buried and closed (forced), every status checked and its absence
/// verified. A launch tab that still owns a live connection is left open, and the session
/// alive, with the commands to finish by hand. The session is killed only while it is still
/// exactly the created one; the test-mode marker is removed.
///
/// Safety (PLAN.md *Unattended-run rules*): only its own session, launch tabs and their tmux
/// connections are ever asked, buried, detached, closed or killed; no other tab, session or
/// connection is touched, nothing is typed into any session, no iTerm2 preference is written,
/// and remotely nothing is written on the host. Every wait is bounded.
actor E2EBuryRun {
  /// Which host the spike runs on.
  enum Kind: Sendable, Equatable {
    /// This Mac's default tmux server.
    case local
    /// The default tmux server of the host at this SSH destination.
    case remote(destination: String)
  }

  /// The number of steps, cleanup included.
  static let stepCount = 12
  /// How old a launch tab must be before the run ends it in any way (iTerm2's short-lived
  /// session warning, PLAN.md D15).
  static let minimumTabAge = AttachCoordinator.Configuration().minimumLaunchTabAge
  /// How old the launch tab is when step 5 detaches it: past iTerm2's 3 s short-lived limit,
  /// but before the helper's 10 s minimum lifetime, so the restored tab stays visible during
  /// the helper's hold and the samples can see it.
  static let earlyDetachAge: Duration = .seconds(5)
  /// How long a bury may take to show in `ListSessions`.
  static let buryListing: Duration = .seconds(5)
  /// How long an attach step watches for iTerm2 burying the launch tab itself.
  static let autoBuryWatch: Duration = .seconds(2)
  /// How long step 10 watches after the kill.
  static let killWatch: Duration = .seconds(8)
  /// The pause between two polls.
  static let pollInterval: Duration = .milliseconds(200)
  /// The pause between two polls while step 10 watches.
  static let killPollInterval: Duration = .milliseconds(100)
  /// The pause between two `ListSessions` samples while step 10 watches a restore's order.
  static let orderSampleInterval: Duration = .milliseconds(25)

  /// Which host.
  let kind: Kind
  /// tmux on the host under test.
  let tmux: any HarnessTmux
  /// The helper iTerm2 runs.
  let helperPath: LaunchHelperPath
  /// The iTerm2 client every step shares.
  let client = ITerm2APIClient()
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
  /// The attaches (no existing-attachment check, so no other connection is ever asked).
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
  /// The buried session step 7 left behind, while it may still be listed.
  private var deadBuried: String?
  /// Launch tabs whose attach child step 10 killed (their tmux connection, if still listed, has
  /// no client: a `detach-client` would only be typed into the helper).
  private var killedGateways: Set<String> = []
  /// Whether step 10 killed the attach child (otherwise step 11 detaches cleanly).
  private var killed = false
  /// Per launch tab (its session id), whether iTerm2 buried it itself after the attach (S6,
  /// its auto-hide setting).
  private var autoBuried: [String: Bool] = [:]
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
    let recorder = self.recorder
    coordinator = AttachCoordinator(
      iTerm2: client, discovery: discovery, store: requests, helperPath: helperPath,
      existingAttachments: .off, onUpdate: { recorder.record($0) })
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

  /// Setup, then steps 1–11, stopping at the first failure. Cleanup is `cleanUp()`.
  func runSteps() async {
    guard await setUpRun() else { return }
    guard await step(1, "create session", { try await self.createSession() }),
      await step(2, "discover", { try await self.discoverSession() }),
      await step(3, "attach", { try await self.attachStep(suppressingDisinter: false) }),
      await step(4, "bury (a)", { try await self.buryStep() }),
      await step(5, "detach buried (c)", { try await self.detachBuried() }),
      await step(
        6, "attach without Disinter", { try await self.attachStep(suppressingDisinter: true) }),
      await step(7, "detach without Disinter (b)", { try await self.detachWithoutDisinter() }),
      await step(8, "close buried (d)", { try await self.closeDeadBuried() }),
      await step(
        9, "attach for the kill", { try await self.attachStep(suppressingDisinter: false) }),
      await step(10, "kill attach child (e)", { try await self.killAttachChild() }),
      await step(11, "close after the kill (d)", { try await self.closeAfterKill() })
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

  /// Checks iTerm2's API (and, remotely, that the host answers over ssh and whether ssh shares
  /// connections), and turns on the helper's test mode.
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
    setUp = true
    var line =
      "setup: iTerm2 API connected (protocol \(status.protocolVersion ?? "?")), helper test mode "
      + "on; \(foreign) tmux connection(s) this run did not open, never asked"
    if case .remote = kind {
      line +=
        "; ssh connection sharing for the destination: \(sharing) (step 10 kills the local ssh "
        + "child only when it is off)"
    }
    output(line)
    return true
  } // End of func setUpRun()

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

  /// Steps 3, 6 and 9: attaches the session through a new launch tab (with the helper's
  /// `Disinter` suppressed when asked), requires it confirmed with its first tab activated
  /// (S6: bury only once a tmux window shows), and waits for the helper's digest to record its
  /// attach child's process id.
  private func attachStep(suppressingDisinter: Bool) async throws -> String {
    guard let target else { throw StepFailure("no target from discovery") }
    requests.setSuppressesDisinter(suppressingDisinter)
    let result = await coordinator.attach(target)
    let confirmedAt = ContinuousClock.now
    requests.setSuppressesDisinter(false)
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
      "confirmed in \(milliseconds(result.timings.confirmed ?? .zero)) ms; helper pid "
        + "\(digest.helperPID), attach child pid \(childPID)"
        + (suppressingDisinter ? "; the request carries testSuppressDisinter" : ""))
    let selfBuried = try await waitForPlace(gateway, in: [.buried], within: Self.autoBuryWatch)
    autoBuried[gateway] = selfBuried.elapsed != nil
    observe(
      selfBuried.elapsed == nil
        ? "iTerm2 left the launch tab in its tab for \(milliseconds(Self.autoBuryWatch)) ms after "
          + "the confirmation (its auto-hide setting is off)"
        : "iTerm2 buried the launch tab itself once its first tmux tab opened (S6: its "
          + "\"Automatically bury the tmux client session\" setting is on); it was buried "
          + "\(milliseconds(ContinuousClock.now - confirmedAt)) ms after the confirmation at the "
          + "latest")
    return "confirmed on connection \(connectionID), tab \(tabID) activated, launch tab \(gateway)"
  } // End of func attachStep(suppressingDisinter:)

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

  /// Buries `attachment`'s launch tab (bound to its connection) and waits until iTerm2 lists it
  /// as buried. A refused bury fails the step: the steps after it need a buried tab.
  private func bury(_ attachment: Attachment) async throws -> Duration? {
    let start = ContinuousClock.now
    do {
      try await client.buryLaunchTab(
        sessionID: attachment.gateway, ifOwnsTmuxConnection: attachment.connectionID)
    } catch let error as ITerm2Error {
      observe("the bury failed: \(error.kind) (\(error.errorDescription ?? ""))")
      throw StepFailure("the bury did not succeed; the following steps need a buried launch tab")
    }
    observe(
      "SetProperty buried=true answered OK in \(milliseconds(ContinuousClock.now - start)) ms")
    let listed = try await waitForPlace(
      attachment.gateway, in: [.buried], within: Self.buryListing)
    if let elapsed = listed.elapsed {
      observe(
        "ListSessions lists the launch tab in buried_sessions \(milliseconds(elapsed)) ms later")
    } else {
      observe(
        "after \(Self.buryListing) ListSessions still lists the launch tab \(listed.last.rawValue)")
    }
    return listed.elapsed
  } // End of func bury(_:)

  /// Observes what `GetProperty` `buried` answers for `gateway` (`label` says when).
  private func observeBuriedProperty(_ gateway: String, label: String) async throws {
    do {
      let value = try await client.sessionProperty(
        ITerm2API.SessionProperty.buried, sessionID: gateway)
      observe("GetProperty buried answers \(value ?? "no value") \(label)")
    } catch let error as ITerm2Error {
      observe("GetProperty buried failed \(label): \(error.kind)")
    }
  } // End of func observeBuriedProperty(_:label:)

  /// Step 4, when iTerm2 buried the launch tab itself: restores it (`SetProperty` `buried`
  /// false), observing where it comes back (S8), so the bury that follows starts from a tab.
  private func restoreSelfBuried(_ attachment: Attachment) async throws {
    observe(
      "iTerm2 had buried the launch tab itself before muxFinder's bury; the run restores it "
        + "first, so the bury starts from a tab")
    try await observeBuriedProperty(attachment.gateway, label: "while buried by iTerm2")
    let before = try await client.listSessions()
    let start = ContinuousClock.now
    try await client.setBuried(false, sessionID: attachment.gateway)
    let answered = ContinuousClock.now - start
    let back = try await waitForPlace(attachment.gateway, in: [.inTab], within: Self.buryListing)
    guard let elapsed = back.elapsed else {
      throw StepFailure(
        "after SetProperty buried=false the launch tab is still listed \(back.last.rawValue)")
    }
    let after = try await client.listSessions()
    let window = after.placement(ofSession: attachment.gateway)?.window
    let known = Set(before.windows.compactMap(\.windowID))
    let isNew = window?.windowID.map { !known.contains($0) } ?? false
    observe(
      "SetProperty buried=false answered OK in \(milliseconds(answered)) ms; the launch tab is "
        + "in a tab \(milliseconds(elapsed)) ms later, in "
        + (isNew ? "a new window" : "a window that was listed before")
        + " (\(window?.tabs.count ?? 0) tab(s)); windows: \(before.windows.count) before, "
        + "\(after.windows.count) after")
  } // End of func restoreSelfBuried(_:)

  /// Step 4 (a): the bury and what iTerm2 shows afterwards.
  private func buryStep() async throws -> String {
    guard let attachment = current else { throw StepFailure("no attachment") }
    if try await place(of: attachment.gateway) == .buried {
      try await restoreSelfBuried(attachment)
    }
    try await observeBuriedProperty(attachment.gateway, label: "while in a tab")
    let before = try await client.listSessions()
    let window = before.placement(ofSession: attachment.gateway)?.window
    let tabsBefore = before.tabs(ofTmuxConnection: attachment.connectionID).count
    _ = try await bury(attachment)
    let after = try await client.listSessions()
    let place = GatewayPlace(of: attachment.gateway, in: after)
    if let windowID = window?.windowID {
      let windowLeft = after.windows.contains { $0.windowID == windowID }
      observe(
        "the launch tab's window (\(window?.tabs.count ?? 0) tab(s) before) "
          + (windowLeft ? "is still listed" : "is gone"))
    }
    let tabsAfter = after.tabs(ofTmuxConnection: attachment.connectionID).count
    observe("the connection's tmux tabs: \(tabsBefore) before, \(tabsAfter) after the bury")
    let connections = try await client.listTmuxConnections()
    let owner = connections.first { $0.connectionID == attachment.connectionID }?.owningSessionID
    observe(
      "ListConnections lists the connection "
        + (owner == nil
          ? "no more"
          : owner == attachment.gateway
            ? "still owned by the launch tab" : "owned by another session"))
    try await observeBuriedProperty(attachment.gateway, label: "after the bury")
    do {
      try await client.setBuried(true, sessionID: attachment.gateway)
      observe("a second bury of the buried session answers OK")
    } catch let error as ITerm2Error {
      observe("a second bury of the buried session failed: \(error.kind)")
    }
    return "SetProperty answered OK; the launch tab is listed \(place.rawValue)"
  } // End of func buryStep()

  /// Sends `detach-client` to `attachment`'s connection, bound to its launch tab. When iTerm2 no
  /// longer lists the buried tab as the owner, that is observed, the tab is restored and the
  /// bound detach is tried once more.
  private func boundDetach(_ attachment: Attachment) async throws {
    do {
      _ = try await client.sendTmuxCommand(
        ConnectionIdentity.detachCommand, connectionID: attachment.connectionID,
        ownedBy: attachment.gateway)
    } catch ITerm2Error.tmuxConnectionNotOwned {
      observe("the bound detach was refused: the buried launch tab is not listed as the owner")
      try await client.setBuried(false, sessionID: attachment.gateway)
      _ = try await client.sendTmuxCommand(
        ConnectionIdentity.detachCommand, connectionID: attachment.connectionID,
        ownedBy: attachment.gateway)
      observe("restored first, the bound detach went out")
    }
  } // End of func boundDetach(_:)

  /// Waits until `attachment`'s connection is gone and its helper's result arrived (takes it);
  /// throws when the connection stays.
  private func waitForEnd(_ attachment: Attachment) async throws -> LaunchResult? {
    let closed = try await poll(timeout: .seconds(10)) { () -> Bool? in
      let open = try await self.client.listTmuxConnections().contains {
        $0.connectionID == attachment.connectionID && $0.owningSessionID == attachment.gateway
      }
      return open ? nil : true
    }
    guard closed == true else {
      throw StepFailure("the connection stayed open after detach-client")
    }
    return try await poll(timeout: .seconds(15)) { () -> LaunchResult? in
      try self.store.takeResult(attachment.launchID)
    }
  } // End of func waitForEnd(_:)

  /// Observes how the helper ended: its exit status and failure kind.
  private func observeResult(_ result: LaunchResult?) {
    guard let result else {
      observe("no helper result arrived within 15 s")
      return
    }
    observe(
      "the helper's result: exit \(result.exitStatus)"
        + (result.failure.map { ", \($0.kind)" } ?? ", clean"))
  }

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

  /// During the helper's hold (its first restore over, its last not yet recorded), buries
  /// `attachment`'s launch tab again when it is in a tab: where iTerm2's default setting would
  /// have left it after the tmux end, and what a bury late in the race does. Returns when the
  /// bury was answered, or `nil` when nothing was buried.
  private func buryDuringHold(_ attachment: Attachment) async throws -> Date? {
    let now = try await place(of: attachment.gateway)
    let ended =
      refreshDigest(attachment.launchID)?.tabRestores?.contains { $0.stage == .beforeExit } == true
    guard now == .inTab, !ended, ProcessCheck.isAlive(attachment.digest.helperPID) else {
      observe(
        "not buried during the hold: the launch tab is \(now.rawValue)"
          + (ended ? " and the helper's last restore has run" : ""))
      return nil
    }
    try await client.setBuried(true, sessionID: attachment.gateway)
    let buriedAt = Date()
    let listed = try await waitForPlace(attachment.gateway, in: [.buried], within: Self.buryListing)
    observe(
      "buried again during the helper's hold (as the default setting leaves it after the tmux "
        + "end): SetProperty answered OK, the tab is listed \(listed.last.rawValue)")
    return buriedAt
  } // End of func buryDuringHold(_:)

  /// Step 5 (c): a bound detach of the buried launch tab at `earlyDetachAge`, sampled; then a
  /// bury during the hold and the helper's last restore, sampled.
  private func detachBuried() async throws -> String {
    guard let attachment = current else { throw StepFailure("no attachment") }
    try await waitUntilAge(attachment, Self.earlyDetachAge)
    let sampler = GatewaySampler(attachment.gateway, client: client)
    let sentAt = Date()
    let result: LaunchResult?
    let holdBury: Date?
    let gone: (elapsed: Duration?, last: GatewayPlace)
    do {
      try await boundDetach(attachment)
      result = try await waitForEnd(attachment)
      _ = try await restores(of: attachment.launchID, through: .afterChild, within: .seconds(5))
      holdBury = try await buryDuringHold(attachment)
      gone = try await waitForPlace(attachment.gateway, in: [.absent], within: .seconds(25))
    } catch {
      _ = await sampler.stop()
      throw error
    }
    let samples = await sampler.stop()
    current = nil
    observeResult(result)
    let restores = try await restores(
      of: attachment.launchID, through: .beforeExit, within: .seconds(3))
    observeRestores(restores)
    observeTmuxEndRestore(
      restores: restores, samples: samples, detachSentAt: sentAt, until: holdBury,
      iTerm2Restores: autoBuried[attachment.gateway] == true)
    if let holdBury {
      observeOrder(of: .beforeExit, restores: restores, samples: samples, since: holdBury)
      if gone.elapsed != nil {
        observe(
          "the bury during the hold was undone by the helper's last restore: the tab ended with "
            + "its helper instead of staying as a dead buried session (as in step 7, without "
            + "Disinter)")
      }
    }
    let left = gone.elapsed == nil ? "still listed \(gone.last.rawValue)" : "nothing left behind"
    observe(
      gone.elapsed.map {
        "the launch tab was gone \(milliseconds($0)) ms after the run began waiting for that "
          + "(after the bury during the hold)"
      } ?? "the launch tab is \(gone.last.rawValue) 25 s after the detach (cleanup handles it)")
    if gone.last == .buried { deadBuried = attachment.gateway }
    let survived = try await sessionSurvives()
    return "detached while buried: \(left); \(survived)"
  } // End of func detachBuried()

  /// Observes who brought the launch tab back at the tmux end. With iTerm2's auto-hide setting
  /// on (`iTerm2Restores`, seen at the attach), iTerm2 restores it itself when it reads tmux's
  /// `%exit`, before it reads the helper's first restore, so that restore cannot be seen; else
  /// the helper's first restore did, and its order is observed (`observeOrder`) on the samples
  /// sent before `until` (the next bury).
  private func observeTmuxEndRestore(
    restores: [LaunchArgvDigest.TabRestoreRecord],
    samples: [GatewaySample],
    detachSentAt: Date,
    until: Date?,
    iTerm2Restores: Bool
  ) {
    let inTab = samples.first { $0.place == .inTab && $0.sentAt > detachSentAt }
    observe(
      "\(samples.count) ListSessions samples; the first one in a tab after the detach answered "
        + (inTab.map { "\(milliseconds(from: detachSentAt, to: $0.receivedAt)) ms" } ?? "never")
        + " after it")
    guard !iTerm2Restores else {
      observe(
        "with iTerm2's auto-hide setting on, iTerm2 restored the tab itself when it read tmux's "
          + "%exit (S5), so the helper's first restore is not seen here")
      return
    }
    let bounded = samples.filter { sample in until.map { sample.sentAt < $0 } ?? true }
    observeOrder(of: .afterChild, restores: restores, samples: bounded, since: detachSentAt)
  } // End of func observeTmuxEndRestore(restores:samples:detachSentAt:until:iTerm2Restores:)

  /// Observes the order of the helper's `stage` restore and the samples sent after `since`
  /// (when the tab was last made buried): whether a sample sent after the status report answer
  /// still saw the session buried (the answer came before the restore, so S7 does not hold),
  /// or every later sample saw it restored or gone.
  private func observeOrder(
    of stage: LaunchArgvDigest.TabRestoreRecord.Stage,
    restores: [LaunchArgvDigest.TabRestoreRecord],
    samples: [GatewaySample],
    since: Date
  ) {
    guard let record = restores.first(where: { $0.stage == stage }) else {
      observe("no \(stage.rawValue) restore was recorded; its order cannot be told")
      return
    }
    guard record.outcome == "answered" else {
      observe("the \(stage.rawValue) status report was \(record.outcome); the order cannot be told")
      return
    }
    let watched = samples.filter { $0.sentAt > since }
    let lastBuried = watched.last { $0.place == .buried && $0.sentAt < record.endedAt }
    let laterBuried = watched.filter { $0.sentAt > record.endedAt && $0.place == .buried }
    let later = watched.filter { $0.sentAt > record.endedAt }
    let restored = watched.contains { $0.place == .inTab && $0.sentAt > record.requestedAt }
    let lastBuriedText = lastBuried.map { sample -> String in
      let offset = milliseconds(from: record.requestedAt, to: sample.sentAt)
      return offset < 0 ? "\(-offset) ms before the request" : "\(offset) ms after the request"
    }
    observe(
      "\(stage.rawValue): the restore was requested "
        + "\(milliseconds(from: since, to: record.requestedAt)) ms after the tab was buried, "
        + "answered \(record.answeredAfterMilliseconds ?? 0) ms after the request; the last "
        + "sample that saw the tab buried was sent \(lastBuriedText ?? "never")")
    if !laterBuried.isEmpty, !restored {
      observe(
        "\(stage.rawValue): the session was never seen restored: every sample after the request "
          + "listed it buried or gone (Disinter did not bring it back)")
    } else if let firstLate = laterBuried.first {
      observe(
        "\(stage.rawValue): the status report answer came BEFORE the restore: "
          + "\(laterBuried.count) sample(s) sent after the answer still listed the session buried "
          + "(the first \(milliseconds(from: record.endedAt, to: firstLate.sentAt)) ms after it)")
    } else if later.isEmpty {
      observe("\(stage.rawValue): no sample was sent after the status report answer")
    } else {
      observe(
        "\(stage.rawValue): every sample sent after the status report answer (\(later.count)) "
          + "listed the session in a tab or gone: the answer did not come before the restore "
          + "(consistent with S7)")
    }
  } // End of func observeOrder(of:restores:samples:since:)

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

  /// Step 7 (b): bury, a bound detach at `earlyDetachAge` with the helper's `Disinter`
  /// suppressed, where the tab is after the tmux end, a bury during the hold when it was
  /// restored, then whether a dead buried session remains once the helper has exited.
  private func detachWithoutDisinter() async throws -> String {
    guard let attachment = current else { throw StepFailure("no attachment") }
    _ = try await bury(attachment)
    try await waitUntilAge(attachment, Self.earlyDetachAge)
    let sampler = GatewaySampler(attachment.gateway, client: client)
    let sentAt = Date()
    let result: LaunchResult?
    let afterEnd: GatewayPlace
    var holdBury: Date?
    let exited: Bool?
    do {
      try await boundDetach(attachment)
      result = try await waitForEnd(attachment)
      _ = try await restores(of: attachment.launchID, through: .afterChild, within: .seconds(5))
      afterEnd = try await place(of: attachment.gateway)
      if afterEnd == .inTab { holdBury = try await buryDuringHold(attachment) }
      let helper = attachment.digest.helperPID
      exited = try await poll(timeout: .seconds(20)) { () -> Bool? in
        ProcessCheck.isAlive(helper) ? nil : true
      }
      try await Task.sleep(for: .seconds(2))
    } catch {
      _ = await sampler.stop()
      throw error
    }
    let samples = await sampler.stop()
    current = nil
    observeResult(result)
    let firstInTab = samples.first { $0.place == .inTab && $0.sentAt > sentAt }
    observe(
      "after the tmux end (the helper's result and first restore) the launch tab is "
        + "\(afterEnd.rawValue)"
        + (afterEnd == .inTab
          ? ": iTerm2 restored it itself, the first sample in a tab answered "
            + (firstInTab.map { "\(milliseconds(from: sentAt, to: $0.receivedAt)) ms" } ?? "?")
            + " after the detach (S5 with its auto-hide setting on)"
          : afterEnd == .buried ? ": it stayed buried (S5 with the default setting)" : ""))
    if let holdBury {
      let back = samples.contains { $0.place == .inTab && $0.sentAt > holdBury }
      observe(
        back
          ? "a sample after the hold's bury saw the tab in a tab again"
          : "no sample after the hold's bury saw the tab in a tab: nothing restored it")
    }
    observe(exited == true ? "the helper exited" : "the helper still runs 20 s after its result")
    let place = try await place(of: attachment.gateway)
    observeRestores(
      try await restores(of: attachment.launchID, through: .beforeExit, within: .seconds(2)))
    switch place {
    case .buried:
      deadBuried = attachment.gateway
      observe(
        "a dead buried session remained: the launch tab is still in buried_sessions after its "
          + "helper exited (S4)")
    case .inTab:
      observe("the launch tab is in a tab after its helper exited")
    case .absent:
      observe("nothing remained: the launch tab is gone after its helper exited")
    }
    let survived = try await sessionSurvives()
    return
      "detached while buried without Disinter: the launch tab is \(place.rawValue); \(survived)"
  } // End of func detachWithoutDisinter()

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

  /// Step 8 (d): `Close` of the dead buried session step 7 left, while it is buried; restore,
  /// then close, if that left it.
  private func closeDeadBuried() async throws -> String {
    guard let gateway = deadBuried, try await place(of: gateway) == .buried else {
      deadBuried = nil
      observe(
        "no buried session of this run is listed now; step 11 closes the killed attach's launch "
          + "tab, while buried if it stayed so")
      return "nothing buried to close"
    }
    if try await closeObserving(gateway, label: "dead buried") {
      deadBuried = nil
      return "Close removed the dead buried session"
    }
    let ended = await restoreThenClose(gateway)
    observe("restore, then close: \(ended.details.joined(separator: "; "))")
    guard ended.gone else {
      throw StepFailure("the dead buried session could not be removed")
    }
    deadBuried = nil
    return "the dead buried session was removed by restoring, then closing it"
  } // End of func closeDeadBuried()

  /// Step 10 (e): bury, then SIGKILL of only the helper's attach child, and what follows.
  private func killAttachChild() async throws -> String {
    guard let attachment = current, let childPID = attachment.digest.attachChildProcessID else {
      throw StepFailure("no attachment with a recorded attach child")
    }
    if case .remote = kind, sharing != .off {
      observe(
        "not killed: ssh -G shows connection sharing \(sharing) for the destination, so the local "
          + "ssh child may carry other sessions; the attachment is detached in step 11")
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
    _ = try await bury(attachment)
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
    try await watchAfterKill(attachment, killedAt: killedAt)
    let survived = try await sessionSurvives(requiringNoClient: false)
    return "the attach child was killed while buried; \(survived)"
  } // End of func killAttachChild()

  /// What step 10 saw after the kill, as wall-clock times (like the helper's digest).
  struct KillTimeline {
    /// The helper's result, once seen.
    var result: LaunchResult?
    /// When the tab's tmux connection left `ListConnections`.
    var connectionGone: Date?
    /// When the connection's tmux tabs were gone.
    var tabsGone: Date?
    /// When a look first saw the launch tab in a tab.
    var firstInTab: Date?
    /// When the run buried it again (after iTerm2 restored it during the helper's first
    /// restore), if it did.
    var reburied: Date?
    /// When a look first saw it in a tab after that.
    var backAfterRebury: Date?
    /// Where it was at the last look.
    var lastPlace = GatewayPlace.buried
  } // End of struct KillTimeline

  /// Watches for `killWatch` after the kill (every `killPollInterval`): the helper's result,
  /// the connection and its tmux tabs, and where the launch tab is. When iTerm2 restores the
  /// tab itself while the helper's first restore is still waiting (its auto-hide setting, S5),
  /// the tab is buried again once, as the default setting would have left it, so the helper's
  /// second restore can be seen. Then observes the timeline and the helper's restores, with a
  /// denser `ListSessions` sampling (`orderSampleInterval`) for the second restore's order.
  private func watchAfterKill(_ attachment: Attachment, killedAt: Date) async throws {
    let sampler = GatewaySampler(
      attachment.gateway, client: client, every: Self.orderSampleInterval,
      limit: Self.killWatch + .seconds(2))
    do {
      let seen = try await watchKilledTab(attachment)
      let samples = await sampler.stop()
      observeKillTimeline(seen, samples: samples, attachment: attachment, killedAt: killedAt)
    } catch {
      _ = await sampler.stop()
      throw error
    }
  } // End of func watchAfterKill(_:killedAt:)

  /// The polling loop of `watchAfterKill(_:killedAt:)`.
  private func watchKilledTab(_ attachment: Attachment) async throws -> KillTimeline {
    let start = ContinuousClock.now
    var seen = KillTimeline()
    while ContinuousClock.now - start < Self.killWatch {
      if seen.result == nil { seen.result = try store.takeResult(attachment.launchID) }
      let connections = try await client.listTmuxConnections()
      if seen.connectionGone == nil,
        !connections.contains(where: {
          $0.connectionID == attachment.connectionID && $0.owningSessionID == attachment.gateway
        })
      {
        seen.connectionGone = Date()
      }
      let sessions = try await client.listSessions()
      let lookedAt = Date()
      if seen.tabsGone == nil, sessions.tabs(ofTmuxConnection: attachment.connectionID).isEmpty {
        seen.tabsGone = lookedAt
      }
      seen.lastPlace = GatewayPlace(of: attachment.gateway, in: sessions)
      if seen.lastPlace == .inTab {
        if seen.firstInTab == nil { seen.firstInTab = lookedAt }
        if seen.reburied != nil, seen.backAfterRebury == nil { seen.backAfterRebury = lookedAt }
        let firstRestoreOver =
          refreshDigest(attachment.launchID)?.tabRestores?.isEmpty == false
        if seen.reburied == nil, !firstRestoreOver {
          try await client.setBuried(true, sessionID: attachment.gateway)
          seen.reburied = Date()
          seen.lastPlace = .buried
        }
      }
      try await Task.sleep(for: Self.killPollInterval)
    } // End of loop watching after the kill
    return seen
  } // End of func watchKilledTab(_:)

  /// Observes what `watchAfterKill` saw, with the helper's restores (the order of the second
  /// against `samples`) and whether it still runs.
  private func observeKillTimeline(
    _ seen: KillTimeline,
    samples: [GatewaySample],
    attachment: Attachment,
    killedAt: Date
  ) {
    let watched = "\(milliseconds(Self.killWatch)) ms"
    let since = { (date: Date) in "\(milliseconds(from: killedAt, to: date)) ms" }
    observeResult(seen.result)
    observe(
      "the tmux connection "
        + (seen.connectionGone.map { "left ListConnections \(since($0)) after the kill" }
          ?? "is still listed after \(watched)"))
    observe(
      "its tmux tabs "
        + (seen.tabsGone.map { "were gone \(since($0)) after the kill" }
          ?? "are still listed after \(watched)"))
    let restores = refreshDigest(attachment.launchID)?.tabRestores ?? []
    observeRestores(restores)
    let first = restores.first { $0.stage == .afterChild }
    let second = restores.first { $0.stage == .afterTmuxModeEnd }
    var timeline =
      "the launch tab "
      + (seen.firstInTab.map { "was first seen in a tab \(since($0)) after the kill" }
        ?? "was never seen in a tab")
    if let firstInTab = seen.firstInTab, let first, firstInTab < first.endedAt {
      timeline +=
        " (while the helper's first restore still waited: iTerm2 restored it itself when the "
        + "line feed ended its tmux mode, S5 with its auto-hide setting on)"
    }
    observe(timeline)
    if let reburied = seen.reburied {
      let valid = second.map { reburied < $0.requestedAt } ?? false
      let request =
        second.map {
          "the helper's second restore was requested "
            + "\(milliseconds(from: reburied, to: $0.requestedAt)) ms later"
        } ?? "the helper made no second restore"
      observe(
        "the run buried it again \(since(reburied)) after the kill, as the default setting would "
          + "have left it; \(request)"
          + (valid ? "" : " (so this does not show the second restore's effect)"))
      if let back = seen.backAfterRebury {
        let request = second.map {
          ", \(milliseconds(from: $0.requestedAt, to: back)) ms after the second restore's request"
        }
        observe("it was back in a tab \(since(back)) after the kill" + (request ?? ""))
      } else {
        observe("it stayed buried until the end of the watch")
      }
      if valid {
        observeOrder(of: .afterTmuxModeEnd, restores: restores, samples: samples, since: reburied)
      }
    }
    observe("the launch tab is listed \(seen.lastPlace.rawValue) after \(watched)")
    let answered = restores.contains { $0.stage != .beforeExit && $0.outcome == "answered" }
    observe(
      answered
        ? "a status report was answered: iTerm2 parses the tab as a terminal again, so the "
          + "explanation the helper wrote next is drawn"
        : "no status report was answered: iTerm2 probably still parses the tab in tmux mode, so "
          + "its explanation is not drawn")
    let alive = ProcessCheck.isAlive(attachment.digest.helperPID)
    observe(
      alive
        ? "the helper still runs (after a failure it waits for Return; this run never types it)"
        : "the helper has exited")
  } // End of func observeKillTimeline(_:attachment:killedAt:)

  /// Step 11 (d): the killed attach's launch tab, buried again if it is in a tab, then closed
  /// while buried (restored and closed if that left it); or, when step 10 skipped the kill, a
  /// clean bound detach.
  private func closeAfterKill() async throws -> String {
    guard let attachment = current else { throw StepFailure("no attachment") }
    try await waitUntilAge(attachment, Self.minimumTabAge)
    guard killed else {
      try await boundDetach(attachment)
      observeResult(try await waitForEnd(attachment))
      current = nil
      return "detached cleanly (nothing was killed)"
    }
    var gone = false
    let running = ProcessCheck.isAlive(attachment.digest.helperPID)
    var now = try await place(of: attachment.gateway)
    if now == .inTab {
      try await client.setBuried(true, sessionID: attachment.gateway)
      now = try await waitForPlace(attachment.gateway, in: [.buried], within: Self.buryListing).last
      observe("buried the launch tab again to close a buried session: listed \(now.rawValue)")
    }
    switch now {
    case .buried:
      gone = try await closeObserving(
        attachment.gateway,
        label: running ? "live buried (its helper waiting for Return)" : "dead buried")
    case .inTab:
      gone = try await closeObserving(attachment.gateway, label: "restored")
    case .absent:
      gone = true
      observe("the launch tab was gone already")
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
    return "the launch tab is gone, its helper ended and no connection is left; \(survived)"
  } // End of func closeAfterKill()

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

  // MARK: - Cleanup

  /// Step 12 (see the type's documentation). Never cancels itself.
  func cleanUp() async {
    let start = ContinuousClock.now
    var actions: [String] = []
    var problems: [String] = []
    var byHand: [String] = []
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
      if created == nil, let recovered = await recoverCreatedSession() {
        created = recovered
        actions.append("found the test session by its name")
      }
      if let created, let arguments = created.killIfUnchangedArguments,
        created.name == sessionName
      {
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
      }
    } // End of the session kill
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
    if !autoBuried.isEmpty {
      output(
        "  OBSERVATION: iTerm2 buried the launch tab itself after "
          + "\(autoBuried.values.filter { $0 }.count) of \(autoBuried.count) attaches")
    }
  } // End of func cleanUp()

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
