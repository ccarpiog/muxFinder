import AppKit
import Darwin
import Foundation
import MuxFinderCore
import os

/// `muxfinder-probe e2e-detach-others --local | --ssh <destination>`: the real check of
/// "Detach other clients" (PLAN.md D37, Phase I-11a), and the harness of its proof. The attach
/// and the call go through an `AttachCoordinator` that buries its launch tab as the app does,
/// over `RecordingITerm2Integration` (every request counted; restores and `Close`s recorded)
/// and an attachment index that asks only connections owned by this run's launch tabs
/// (`AttachmentIndex.Configuration.includes`), so no tmux connection of the user's ever gets a
/// command. The harness's own requests go to the iTerm2 client directly.
///
/// Steps (each prints one PASS or FAIL line, with note lines; the first failure stops the run,
/// then cleanup runs):
/// 1. **create session:** `muxfinder-test-<hex>` with two windows, each running `sleep 600`.
/// 2. **discover:** discovery lists it exactly as created, with its two windows.
/// 3. **attach (bury):** confirmed, its first tab activated, `burial` `buried`, the launch tab
///    in `buried_sessions` and in no tab, iTerm2 showing the session's two windows as tabs of
///    the connection, and the session's only client a control client (the launch tab's).
/// 4. **plain client attached:** a plain control client of the harness's own
///    (`BackgroundControlClient`: `tmux -u -C attach-session -t '=<name>'`, remotely through
///    noninteractive ssh with no connection sharing) is the session's second client (locally
///    with the spawned process's own pid).
/// 5. **confirmation for another session:** the call with a confirmation naming another key
///    (the same tmux session under another host id) ends `notConfirmed`, and nothing ran: no
///    discovery, no iTerm2 request, both clients still attached.
/// 6. **detach other clients:** the call with the session's own confirmation ends
///    `detached(count: 1)` (one other client listed, checked and detached by name, its
///    `detach-client` confirmed by tmux), keeping this run's attachment (its connection and
///    launch tab) with no other attachment here; the call returns no earlier than
///    `minimumTabAge` after the plain client was started (the age rule for every client
///    detached, PLAN.md D37), and when the plain client was started less than
///    `minimumTabAge` minus `youngMargin` before the call, the call reports a wait for young
///    clients; the plain client prints `%exit` and exits 0 by itself within
///    `plainExitBudget` of the call's return.
/// 7. **attachment kept:** looking every `holdPollInterval` until `holdTime` after the call's
///    return, the iTerm2 tabs and sessions showing the session's tmux windows keep exactly the
///    ids they had right before the call (none closed or reopened); then the launch tab still
///    owns its connection, is still in `buried_sessions` and in no tab, the connection still
///    shows the session (the identity check), the session's only client is the launch tab's,
///    and the coordinator sent no restore or `Close` that may have touched the launch tab.
/// 8. **detach by connection:** the coordinator's `detach(connectionID:gatewaySessionID:
///    launchID:)`: its `detach-client` is answered with its (empty) output, so a command that
///    prints nothing still counts as answered (`ITerm2Error.tmuxCommandFailed` is only for an
///    answer without output), the connection closes, the helper exits 0, the tmux tabs close,
///    the launch tab leaves its tab and `buried_sessions` by itself (`checkLaunchTabLeft`), and
///    the session survives with no client.
///
/// **Cleanup** (step 9, on every way out, SIGINT and SIGTERM included): the plain client is
/// ended (`BackgroundControlClient.stop()`); once every launch tab of the run is 10 s old, a
/// bound `detach-client` for each connection one of them still owns, then each launch tab of
/// the run still listed is restored if buried and closed (forced), every status checked and its
/// absence verified. A launch tab that still owns a live connection is left open, and the
/// session alive, with the commands to finish by hand. The session is killed only while it is
/// still exactly the created one; the helper results nobody took are removed.
///
/// Safety (PLAN.md *Unattended-run rules*): only its own session, launch tabs and their tmux
/// connections are ever asked, detached, closed or killed; no other tab, session or connection
/// is touched, nothing is typed into any session, no iTerm2 preference is read or written, and
/// remotely nothing is written on the host. Every wait is bounded.
actor E2EDetachOthersRun {
  /// The number of steps, cleanup included.
  static let stepCount = 9
  /// The coordinator's budgets (the defaults, as in the app).
  static let configuration = AttachCoordinator.Configuration()
  /// How old a launch tab must be before the run ends it (iTerm2's short-lived session
  /// warning, PLAN.md D15).
  static let minimumTabAge = configuration.minimumLaunchTabAge
  /// How many windows the test session has.
  static let windowCount = 2
  /// How long a confirmed attach's launch tab may take to show only in `buried_sessions`.
  static let buryListing: Duration = .seconds(5)
  /// How long iTerm2 may take to show every window of the session as a tab of the connection.
  static let tabsBudget: Duration = .seconds(5)
  /// How long the plain control client may take to show up in `list-clients` (remotely ssh
  /// connects and logs in first).
  static let plainAttachBudget: Duration = .seconds(15)
  /// How long the plain control client may take to exit after the call returned.
  static let plainExitBudget: Duration = .seconds(10)
  /// How much of `minimumTabAge` the call's own lookups (discovery, the index, the identity
  /// check) may take before tmux's clock is read: a plain client started less than
  /// `minimumTabAge` minus this before the call must be waited for.
  static let youngMargin: Duration = .seconds(5)
  /// How long after the call's return the iTerm2 attachment is watched.
  static let holdTime: Duration = .seconds(2)
  /// The pause between two looks while the attachment is watched.
  static let holdPollInterval: Duration = .milliseconds(250)
  /// How long a detached launch tab may take to leave iTerm2 by itself (see `E2EBuryRun`).
  static let strandedGatewayWait: Duration = .seconds(10)
  /// The pause between two polls.
  static let pollInterval: Duration = .milliseconds(200)

  /// Which host.
  let kind: E2EBuryRun.Kind
  /// tmux on the host under test.
  let tmux: any HarnessTmux
  /// The helper iTerm2 runs.
  let helperPath: LaunchHelperPath
  /// The iTerm2 client every step shares.
  let client = ITerm2APIClient()
  /// What the coordinator and its index talk to: `client`, every request counted and each
  /// restore and `Close` recorded.
  let coordinatorITerm2: RecordingITerm2Integration
  /// The real launch directory.
  let store = LaunchStore()
  /// Real discovery, counted.
  let discovery: CountingDiscovery
  /// The host under test.
  let host: HostConfig
  /// The coordinator's updates, including every launch tab it opened.
  let recorder = UpdateRecorder()
  /// The coordinator's attachment index: only connections owned by this run's launch tabs.
  let index: AttachmentIndex
  /// The attach, the call and the detach.
  let coordinator: AttachCoordinator
  /// The test session's name.
  let sessionName = "muxfinder-test-" + String(format: "%08x", UInt32.random(in: .min ... .max))

  /// The run's attachment.
  struct Attachment: Sendable {
    /// The launch.
    let launchID: LaunchToken
    /// The launch tab's session.
    let gateway: String
    /// Its tmux connection.
    let connectionID: String
  }

  /// One tab of the connection as iTerm2 lists it: the ids that change when iTerm2 closes and
  /// reopens a tmux window.
  struct TmuxTab: Sendable, Hashable {
    /// The window holding it.
    let windowID: String?
    /// The tab.
    let tabID: String?
    /// The tmux window it shows.
    let tmuxWindowID: String?
    /// Its iTerm2 sessions (panes), in the tab's order.
    let sessionIDs: [String]
  }

  /// The created session, once known.
  private var created: CreatedSession?
  /// When step 1 started `new-session` (seconds since 1970).
  private var creationStartedAt: Int64?
  /// What step 2's discovery reported.
  private var discovered: DiscoveryResult?
  /// The attach target discovery found.
  private var target: AttachTarget?
  /// The current attachment.
  private var current: Attachment?
  /// The tmux client pid of the launch tab's attachment (`#{client_pid}`).
  private var launchClientPID: String?
  /// The plain control client, while it may run.
  private var plainClient: BackgroundControlClient?
  /// Its tmux client pid (`#{client_pid}`).
  private var plainClientPID: String?
  /// When the plain control client's process was started (before tmux created its client).
  private var plainStartedAt: ContinuousClock.Instant?
  /// The connection's tabs right before the call.
  private var tabsBefore: [TmuxTab] = []
  /// When the call returned.
  private var callReturnedAt: ContinuousClock.Instant?
  /// Every launch of the run, so cleanup takes the helper results nobody took.
  private var launchIDs: [LaunchToken] = []
  /// `tmux -V`, once the header asked.
  private var tmuxVersion: String?
  /// Whether setup succeeded.
  private var setUp = false
  /// Steps that passed.
  private(set) var passedCount = 0
  /// The note lines of the current step.
  private var lines: [String] = []

  /// Creates the run.
  init(kind: E2EBuryRun.Kind, tmux: any HarnessTmux, helperPath: LaunchHelperPath) {
    self.kind = kind
    self.tmux = tmux
    self.helperPath = helperPath
    switch kind {
    case .local:
      host = HostConfig(displayName: "This Mac", mode: .local)
    case .remote(let destination):
      host = HostConfig(displayName: "Remote host", mode: .ssh, sshDestination: destination)
    }
    discovery = CountingDiscovery(base: DiscoveryProbe())
    coordinatorITerm2 = RecordingITerm2Integration(base: client)
    let recorder = self.recorder
    index = AttachmentIndex(
      iTerm2: coordinatorITerm2,
      configuration: .init(includes: { connection in
        guard let owner = connection.owningSessionID else { return false }
        return recorder.isLaunchTab(owner)
      }))
    // The coordinator buries each launch tab once attached (PLAN.md D29), as in the app.
    coordinator = AttachCoordinator(
      iTerm2: coordinatorITerm2, discovery: discovery, store: store, helperPath: helperPath,
      configuration: Self.configuration, existingAttachments: .index(index),
      onUpdate: { recorder.record($0) })
  } // End of init(kind:tmux:helperPath:)

  /// The command's name for the output.
  nonisolated var name: String {
    kind == .local ? "e2e-detach-others --local" : "e2e-detach-others --ssh"
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

  /// Setup, then steps 1–8, stopping at the first failure. Cleanup is `cleanUp()`.
  func runSteps() async {
    guard await setUpRun() else { return }
    guard await step(1, "create session", { try await self.createSession() }),
      await step(2, "discover", { try await self.discoverSession() }),
      await step(3, "attach (bury)", { try await self.attachStep() }),
      await step(4, "plain client attached", { try await self.attachPlainClient() }),
      await step(
        5, "confirmation for another session", { try await self.otherSessionConfirmation() }),
      await step(6, "detach other clients", { try await self.detachOtherClientsStep() }),
      await step(7, "attachment kept", { try await self.attachmentKept() }),
      await step(8, "detach by connection", { try await self.detachByConnection() })
    else { return }
  } // End of func runSteps()

  /// Runs one step and prints its PASS or FAIL line, then its note lines. Returns whether it
  /// passed.
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

  /// Adds a note line to the current step.
  private func note(_ text: String) {
    lines.append("note: \(text)")
  }

  /// Checks iTerm2's API (and, remotely, that the host answers over ssh).
  private func setUpRun() async -> Bool {
    if case .remote(let destination) = kind, tmuxVersion == nil {
      output(
        "FAIL setup: \(destination) did not answer tmux -V over ssh (BatchMode); check that it "
          + "is reachable with key authentication and has tmux")
      return false
    }
    let status = await client.status()
    guard status.isConnected else {
      let kind = status.error?.kind ?? "unknown"
      let hint = kind == "timedOut" ? "; a modal iTerm2 dialog may be open" : ""
      output("FAIL setup: iTerm2's API is not reachable (\(kind)\(hint))")
      return false
    }
    guard let foreign = try? await client.listTmuxConnections().count else {
      output("FAIL setup: iTerm2's tmux connections could not be listed")
      return false
    }
    setUp = true
    output(
      "setup: iTerm2 API connected (protocol \(status.protocolVersion ?? "?")), the coordinator "
        + "buries its launch tabs (PLAN.md D29); \(foreign) tmux connection(s) this run did not "
        + "open, never asked")
    return true
  } // End of func setUpRun()

  /// Step 1: the session, two windows running `sleep 600`.
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
    let window = try await tmux.run([
      "new-window", "-d", "-t", record.sessionID.rawValue + ":", "sleep", "600",
    ])
    guard window.succeeded else {
      throw StepFailure("new-window failed: \(window.standardError.prefix(200))")
    }
    return "\(record.sessionID) created with \(Self.windowCount) windows, each running sleep 600"
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

  /// Step 2: discovery lists the session exactly as created, with its windows.
  private func discoverSession() async throws -> String {
    guard let created else { throw StepFailure("no test session") }
    let result = try await discovery.discover(host)
    guard case .ok(let sessions) = result.status else {
      throw StepFailure("discovery reported \(result.status.kind)")
    }
    guard let session = sessions.first(where: { $0.key.sessionID == created.sessionID }),
      created.matches(session)
    else { throw StepFailure("discovery did not report the created session as it was") }
    guard session.windowCount == Self.windowCount else {
      throw StepFailure("discovery reported \(session.windowCount) window(s)")
    }
    discovered = result
    target = AttachTarget(host: host, session: session)
    return "\(created.sessionID) found as created, \(session.windowCount) windows "
      + "(\(milliseconds(result.duration)) ms)"
  } // End of func discoverSession()

  /// Step 3: attaches the session through a new launch tab, requires it confirmed with its
  /// first tab activated, the launch tab buried, both windows shown as tabs of the connection
  /// and the session's one client a control client, whose pid it records.
  private func attachStep() async throws -> String {
    guard let target else { throw StepFailure("no target from discovery") }
    let result = await coordinator.attach(target)
    launchIDs.append(result.launchID)
    guard result.isConfirmed, let connectionID = result.connectionID,
      let gateway = result.gatewaySessionID
    else {
      throw StepFailure(
        "attach ended \(result.state.kind): \(result.failure?.kind ?? "?") "
          + "\(result.failure?.detail ?? "")")
    }
    current = Attachment(launchID: result.launchID, gateway: gateway, connectionID: connectionID)
    guard case .activated(let tabID) = result.activation else {
      throw StepFailure("the first tab was not activated: \(String(describing: result.activation))")
    }
    guard result.burial == .buried else {
      throw StepFailure(
        "the coordinator did not bury the launch tab: \(result.burial?.kind ?? "no outcome") "
          + "(\(result.burial?.detail ?? "-"))")
    }
    let listed = try await waitForPlace(gateway, in: [.buried], within: Self.buryListing)
    guard listed.elapsed != nil else {
      throw StepFailure(
        "\(Self.buryListing) after the attach the launch tab is listed \(listed.last.rawValue), "
          + "not only in buried_sessions")
    }
    let tabs = try await poll(timeout: Self.tabsBudget) { () -> [TmuxTab]? in
      let tabs = try await self.tmuxTabs(of: connectionID)
      return tabs.count == Self.windowCount ? tabs : nil
    }
    guard let tabs else {
      throw StepFailure(
        "iTerm2 did not show the session's \(Self.windowCount) windows as tabs of the connection "
          + "within \(Self.tabsBudget)")
    }
    let clients = try await clientLines(of: target.key.sessionID)
    guard clients.count == 1, let only = clients.first, only.hasSuffix("\t1") else {
      throw StepFailure(
        "the session's clients after the attach: \(clients.count), not one control client")
    }
    launchClientPID = String(only.dropLast(2))
    note(
      "confirmed in \(ms(result.timings.confirmed)) ms; burial buried, the launch tab in "
        + "buried_sessions and in no tab; \(tabs.count) tmux tabs with "
        + "\(tabs.flatMap(\.sessionIDs).count) sessions")
    return "confirmed on connection \(connectionID), tab \(tabID) activated, launch tab "
      + "\(gateway) buried; the session's one client is the launch tab's control client"
  } // End of func attachStep()

  /// Step 4: starts the plain control client and waits until it is the session's second
  /// client (a control client; locally with the spawned process's own pid).
  private func attachPlainClient() async throws -> String {
    guard let target, let launchClientPID else { throw StepFailure("no attachment") }
    let command = tmux.controlClientCommand(attachingTo: sessionName)
    plainStartedAt = ContinuousClock.now
    let plain = try BackgroundControlClient.start(
      executable: command.executable, arguments: command.arguments,
      environment: command.environment)
    plainClient = plain
    let id = target.key.sessionID
    let found = try await poll(timeout: Self.plainAttachBudget) { () -> String? in
      guard plain.isRunning else {
        throw StepFailure(
          "the plain control client ended before attaching (\(plain.errorText.prefix(120)))")
      }
      let clients = try await self.clientLines(of: id)
      guard clients.count == 2, clients.allSatisfy({ $0.hasSuffix("\t1") }),
        clients.contains("\(launchClientPID)\t1")
      else { return nil }
      return clients.first { $0 != "\(launchClientPID)\t1" }.map { String($0.dropLast(2)) }
    }
    guard let pid = found else {
      throw StepFailure("the plain control client did not attach within \(Self.plainAttachBudget)")
    }
    if tmux.isLocal, pid != String(plain.processID) {
      throw StepFailure("the session's second client is not the plain control client")
    }
    plainClientPID = pid
    return "the plain control client (tmux client pid \(pid)) is the session's second client, "
      + "next to the launch tab's (\(launchClientPID))"
  } // End of func attachPlainClient()

  /// Step 5: a confirmation naming another key (the same tmux session under another host id)
  /// runs nothing: `notConfirmed`, no discovery, no iTerm2 request, both clients still there.
  private func otherSessionConfirmation() async throws -> String {
    guard let target, let launchClientPID, let plainClientPID, let plain = plainClient else {
      throw StepFailure("no attachment or plain client")
    }
    let otherKey = SessionKey(
      hostID: UUID(), server: target.key.server, sessionID: target.key.sessionID)
    let requests = await coordinatorITerm2.forwardedCallCount
    let discoveries = discovery.count
    let result = await coordinator.detachOtherClients(
      of: target, confirmation: .detachOtherClients(of: otherKey))
    let requestsAfter = await coordinatorITerm2.forwardedCallCount
    guard result.outcome == .notConfirmed else {
      throw StepFailure("the call ended \(result.outcome.kind), not notConfirmed")
    }
    guard requestsAfter == requests, discovery.count == discoveries else {
      throw StepFailure(
        "the call made \(requestsAfter - requests) iTerm2 request(s) and "
          + "\(discovery.count - discoveries) discovery call(s)")
    }
    let clients = Set(try await clientLines(of: target.key.sessionID))
    guard plain.isRunning, clients == ["\(launchClientPID)\t1", "\(plainClientPID)\t1"] else {
      throw StepFailure("the session's clients changed (\(clients.count) now)")
    }
    return "notConfirmed with no discovery and no iTerm2 request; both clients still attached"
  } // End of func otherSessionConfirmation()

  /// Step 6: the call with the session's own confirmation: `detached(count: 1)`, this run's
  /// attachment kept and none other here, the plain client left until it was `minimumTabAge`
  /// old; the plain client prints `%exit` and exits 0 by itself within `plainExitBudget` of the
  /// call's return.
  private func detachOtherClientsStep() async throws -> String {
    guard let target, let attachment = current, let plain = plainClient,
      let plainStartedAt
    else { throw StepFailure("no attachment or plain client") }
    tabsBefore = try await tmuxTabs(of: attachment.connectionID)
    guard tabsBefore.count == Self.windowCount else {
      throw StepFailure("\(tabsBefore.count) tmux tab(s) right before the call")
    }
    let start = ContinuousClock.now
    let result = await coordinator.detachOtherClients(
      of: target, confirmation: .detachOtherClients(of: target.key))
    let returned = ContinuousClock.now
    callReturnedAt = returned
    guard result.outcome == .detached(count: 1) else {
      var problem = ""
      if case .checkFailed(let failure) = result.outcome {
        problem = " (\(failure.kind): \(failure.detail ?? "-"))"
      }
      throw StepFailure(
        "the call ended \(result.outcome.kind)\(problem), not detached(count: 1)")
    }
    let kept = AttachmentSnapshot.Attachment(
      key: target.key, connectionID: attachment.connectionID, owningSessionID: attachment.gateway)
    guard result.kept == kept, result.otherAttachmentsHere == 0 else {
      throw StepFailure("the call kept another attachment than this run's")
    }
    guard result.listedOthers == 1, result.goneBeforeDetach == 0, result.detachedClients == 1
    else {
      throw StepFailure(
        "the call listed \(result.listedOthers) other client(s), \(result.goneBeforeDetach) gone "
          + "before their check, \(result.detachedClients) detached")
    }
    let plainAgeAtStart = start - plainStartedAt
    guard returned - plainStartedAt >= Self.minimumTabAge else {
      throw StepFailure(
        "the call returned \(milliseconds(returned - plainStartedAt)) ms after the plain client "
          + "was started, before it could be \(Self.minimumTabAge) old")
    }
    if plainAgeAtStart < Self.minimumTabAge - Self.youngMargin, result.ageWait == .zero {
      throw StepFailure(
        "the plain client was started \(milliseconds(plainAgeAtStart)) ms before the call, yet "
          + "the call reported no wait for young clients")
    }
    guard let ended = await plain.waitForExit(within: Self.plainExitBudget) else {
      throw StepFailure(
        "the plain control client was still running \(Self.plainExitBudget) after the call")
    }
    let exitedAfter = milliseconds(ContinuousClock.now - returned)
    guard plain.sawExitNotification else {
      throw StepFailure("the plain control client ended (\(ended)) without printing %exit")
    }
    guard ended == .exited(0) else {
      throw StepFailure("the plain control client printed %exit but ended \(ended), not exit 0")
    }
    plainClient = nil
    note(
      "the call took \(milliseconds(returned - start)) ms (discovery, the index, the identity "
        + "check, tmux's clock and the client listing, the wait for young clients, the check "
        + "right before the detach and one detach-client by name); the plain client was started "
        + "\(milliseconds(plainAgeAtStart)) ms before the call and the call waited "
        + "\(milliseconds(result.ageWait)) ms for it to be \(Self.minimumTabAge) old")
    return "detached(count: 1), keeping connection \(attachment.connectionID) of launch tab "
      + "\(attachment.gateway); the plain control client printed %exit and exited 0 by itself "
      + "within \(exitedAfter) ms of the call's return"
  } // End of func detachOtherClientsStep()

  /// Step 7: until `holdTime` after the call's return, every `holdPollInterval`, the
  /// connection's tabs keep the ids they had right before the call; then the launch tab still
  /// owns the connection, buried and in no tab, the connection still shows the session, the
  /// session's only client is the launch tab's, and the coordinator touched no tab.
  private func attachmentKept() async throws -> String {
    guard let target, let attachment = current, let launchClientPID, let returned = callReturnedAt,
      let discovered, let indexHost = AttachmentIndex.Host(discovered)
    else { throw StepFailure("no attachment") }
    var looks = 0
    while true {
      let now = try await tmuxTabs(of: attachment.connectionID)
      looks += 1
      guard now == tabsBefore else {
        throw StepFailure(
          "look \(looks), \(milliseconds(ContinuousClock.now - returned)) ms after the call: the "
            + "connection's tmux tabs changed (\(tabsBefore.count) tabs with "
            + "\(tabsBefore.flatMap(\.sessionIDs).count) sessions before, \(now.count) tabs with "
            + "\(now.flatMap(\.sessionIDs).count) sessions now; "
            + "\(Set(now).intersection(tabsBefore).count) unchanged)")
      }
      if ContinuousClock.now - returned >= Self.holdTime { break }
      try await Task.sleep(for: Self.holdPollInterval)
    } // End of loop watching the connection's tabs
    let span = milliseconds(ContinuousClock.now - returned)
    let connections = try await client.listTmuxConnections()
    guard
      connections.contains(where: {
        $0.connectionID == attachment.connectionID && $0.owningSessionID == attachment.gateway
      })
    else { throw StepFailure("the launch tab no longer owns its connection") }
    let place = try await place(of: attachment.gateway)
    guard place == .buried else {
      throw StepFailure("the launch tab is listed \(place.rawValue), not only in buried_sessions")
    }
    guard
      case .reported(let reported) = try await index.identify(
        connectionID: attachment.connectionID, owningSessionID: attachment.gateway),
      AttachmentIndex.map(reported, among: [indexHost]) == .mapped(target.key)
    else { throw StepFailure("the connection no longer shows the session") }
    let clients = try await clientLines(of: target.key.sessionID)
    guard clients == ["\(launchClientPID)\t1"] else {
      throw StepFailure(
        "the session's clients: \(clients.count), not only the launch tab's control client")
    }
    let touched = await coordinatorITerm2.restoresAndCloses(of: attachment.gateway)
    guard touched.isEmpty else {
      throw StepFailure("the coordinator sent \(touched.count) restore(s) or Close(s)")
    }
    return "\(looks) looks over \(span) ms after the call: the same \(tabsBefore.count) tmux tabs "
      + "and \(tabsBefore.flatMap(\.sessionIDs).count) sessions (ids unchanged, none closed or "
      + "reopened); the launch tab still owns connection \(attachment.connectionID), buried and "
      + "in no tab; the connection still shows the session, its only client"
  } // End of func attachmentKept()

  /// Step 8: the coordinator's detach by connection (as Detach in the app): the connection
  /// closes, the helper exits 0, the tmux tabs close, the launch tab leaves by itself, and the
  /// session survives with no client.
  private func detachByConnection() async throws -> String {
    guard let attachment = current else { throw StepFailure("no attachment") }
    let detach = await coordinator.detach(
      connectionID: attachment.connectionID, gatewaySessionID: attachment.gateway,
      launchID: attachment.launchID)
    let age = recorder.age(of: attachment.gateway)
    guard detach.commandError != .tmuxConnectionNotOwned else {
      throw StepFailure("the connection is no longer the launch tab's; nothing sent")
    }
    if let error = detach.commandError {
      throw StepFailure("detach-client was not answered with its output (\(error.kind))")
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
    let survived = try await sessionSurvives()
    return "the coordinator detached it at \(age) s; the helper exited 0 and the tmux tabs "
      + "closed; the launch tab left its tab and buried_sessions by itself "
      + "\(milliseconds(left)) ms after the helper's result; \(survived)"
  } // End of func detachByConnection()

  // MARK: - Looks

  /// The tabs iTerm2 lists for the tmux connection `connectionID`, in window and tab order.
  private func tmuxTabs(of connectionID: String) async throws -> [TmuxTab] {
    let sessions = try await client.listSessions()
    var tabs: [TmuxTab] = []
    for window in sessions.windows {
      for tab in window.tabs where tab.tmuxConnectionID == connectionID {
        tabs.append(
          TmuxTab(
            windowID: window.windowID, tabID: tab.tabID, tmuxWindowID: tab.tmuxWindowID,
            sessionIDs: tab.sessions.compactMap(\.uniqueIdentifier)))
      }
    }
    return tabs
  } // End of func tmuxTabs(of:)

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

  /// `list-clients` of the session `id`: one `<client pid>\t<control mode>` line per client.
  private func clientLines(of id: TmuxSessionID) async throws -> [String] {
    let listed = try await tmux.run([
      "list-clients", "-t", id.rawValue, "-F", "#{client_pid}\t#{client_control_mode}",
    ])
    guard listed.succeeded else { throw StepFailure("list-clients failed") }
    return listed.lines
  }

  /// Checks that the test session still exists as created, waiting up to 10 s for it to have
  /// no client.
  private func sessionSurvives() async throws -> String {
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
    guard last[0] == "0" else {
      throw StepFailure("a client stayed attached to the test session (\(last[0]))")
    }
    return "the session survived with no client"
  } // End of func sessionSurvives()

  /// Milliseconds of an optional duration, or -1.
  private func ms(_ duration: Duration?) -> Int {
    duration.map(milliseconds) ?? -1
  }

  // MARK: - Cleanup

  /// Step 9 (see the type's documentation). Never cancels itself.
  func cleanUp() async {
    let start = ContinuousClock.now
    var actions: [String] = []
    var problems: [String] = []
    var byHand: [String] = []
    if let plain = plainClient {
      plainClient = nil
      let ended = await plain.stop()
      actions.append("ended the plain control client (\(ended.map { "\($0)" } ?? "not reaped"))")
      if ended == nil { problems.append("the plain control client could not be reaped") }
    }
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
    if attached.isEmpty { problems += await verifyClean(gateways) }
    await client.disconnect()
    let elapsed = milliseconds(ContinuousClock.now - start)
    let summary = actions.isEmpty ? "nothing to clean" : actions.joined(separator: ", ")
    if problems.isEmpty, setUp {
      passedCount += 1
      output(
        "PASS \(Self.stepCount) cleanup (\(elapsed) ms): \(summary); no test session, plain "
          + "client, launch tab (in a tab or buried) or connection left")
    } else {
      let reason = problems.isEmpty ? "setup failed" : problems.joined(separator: "; ")
      output("FAIL \(Self.stepCount) cleanup (\(elapsed) ms): \(summary); \(reason)")
    }
    for line in byHand { output("  \(line)") }
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

  /// Sends a bound `detach-client` to every connection one of `gateways` owns, then lists until
  /// none of them owns a connection (10 s). Returns the launch tabs that still own one, or
  /// `nil` when the connections could not be listed.
  private func detachLeftovers(_ gateways: Set<String>, actions: inout [String]) async -> [String]?
  {
    guard !gateways.isEmpty else { return [] }
    var sent: Set<String> = []
    let deadline = ContinuousClock.now + .seconds(10)
    while true {
      guard let listed = try? await client.listTmuxConnections() else { return nil }
      let owned = listed.filter { gateways.contains($0.owningSessionID ?? "") }
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
      details.append("Close answered \(E2EBuryRun.names(response.statuses))")
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

  /// What is left of the run: the session, any launch tab (in a tab or buried), connections.
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
    return problems
  } // End of func verifyClean(_:)
} // End of actor E2EDetachOthersRun

/// Real discovery that counts its calls, so `e2e-detach-others` can prove a call ran none.
final class CountingDiscovery: HostDiscovering, Sendable {
  /// The real discovery.
  let base: DiscoveryProbe
  /// Calls so far.
  private let calls = OSAllocatedUnfairLock(initialState: 0)

  /// Wraps `base`.
  init(base: DiscoveryProbe) {
    self.base = base
  }

  /// Counts the call, then forwards it to `base`.
  func discover(_ host: HostConfig) async throws -> DiscoveryResult {
    calls.withLock { $0 += 1 }
    return try await base.discover(host)
  }

  /// Calls so far.
  var count: Int { calls.withLock { $0 } }
} // End of class CountingDiscovery
