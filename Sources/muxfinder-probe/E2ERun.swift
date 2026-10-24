import AppKit
import Foundation
import MuxFinderCore

/// Why a step failed, in plain words.
struct StepFailure: Error {
  /// The explanation.
  let detail: String

  /// Creates a failure.
  init(_ detail: String) {
    self.detail = detail
  }
}

/// One real end-to-end run, `e2e-local` or `e2e-remote` (PLAN.md Phases 4, 5a, 5b, 6a and 6b):
/// its parts, what it created, and the steps.
///
/// Safety (PLAN.md *Unattended-run rules*): it creates, attaches, detaches and kills only its
/// own `muxfinder-test-<random>` session (and, for the Phase 6a steps, sessions whose names
/// start with that name) on the default tmux server of this Mac or of the remote host (the
/// move-here step's plain control client attaches only to that session, by its exact name,
/// and is ended on every way out), and
/// finds each again (to attach, inspect or kill it) only if its server, id, creation time and
/// name are still those `new-session` reported (`CreatedSession`), so a restarted server whose
/// new session reuses the id is never touched; a kill makes that check inside the same tmux
/// command (`killIfUnchanged(_:)`), never in an earlier call. Its attachment index
/// asks only connections owned by launch tabs this run opened
/// (`AttachmentIndex.Configuration.includes`, PLAN.md D16), so no other tmux connection ever
/// gets a command, not even the read-only identity `display-message`. It detaches only
/// connections iTerm2 lists as owned by launch tabs it opened (checked by the coordinator right
/// before `detach-client`), closes only those launch tabs (by the session ids iTerm2 reported
/// when it opened them), and never touches another window, tab, session or tmux session. The
/// coordinator buries each launch tab once attached (PLAN.md D29): the attach steps require it
/// in `buried_sessions` and in no tab, and every detach requires it gone from both by itself
/// before any cleanup (no restore or `Close` of the coordinator's recorded for it), so a
/// stranded launch tab fails its step instead of being cleaned up or closed by the coordinator's
/// recovery. Every
/// wait is bounded, and cleanup (the last step) runs after a failure, a signal (SIGINT, SIGTERM,
/// SIGHUP) or the overall time limit. Remotely it runs tmux only through ssh with a static
/// script and quoted arguments (D3), and writes no file on the remote host.
actor E2ERun {
  /// Which proof this is.
  enum Kind: Sendable {
    /// `e2e-local`: this Mac's default tmux server.
    case local
    /// `e2e-remote <destination>`: the remote host's default tmux server, attached over ssh.
    case remote(destination: String)
  }

  /// The tmux session's shape: windows, and panes per window.
  static let expectedPaneCounts = [1, 2]
  /// The helper's test-only launch delay in the `still waiting` step (PLAN.md D14 *Test
  /// mode*), in seconds: well past the attach's 20 s budget, so the step sees `stillWaiting`
  /// and closes the tab (at about 21 s) long before the delay would run out.
  static let stillWaitingLaunchDelaySeconds = 60
  /// How old a launch tab must be before the run ends it by killing the session or closing the
  /// tab. iTerm2 3.7.6 shows a modal "session ended very soon after starting" warning when a
  /// session ends within 3 s of starting (its `shortLivedSessionDuration` default), and that
  /// warning blocks its API until someone answers it (seen in the first real run). The
  /// coordinator keeps the same age before every detach, and the helper never exits younger
  /// while its tab is visible; this is the coordinator's default.
  static let launchTabMinimumAge = AttachCoordinator.Configuration().minimumLaunchTabAge
  /// How long a confirmed attach's launch tab may take to show only in `buried_sessions` after
  /// the attach returned (PLAN.md D29; the coordinator buried it before returning).
  static let buryListing: Duration = .seconds(5)
  /// How long a detached launch tab may take to leave both iTerm2's tabs and `buried_sessions`
  /// by itself, before any cleanup: the helper restores it (one bounded 2 s exchange), exits,
  /// and the tab closes. The coordinator's recovery of a dead buried tab (a restore and a
  /// forced `Close`, `buriedTabCloseDelay` after its helper's result was first seen) may fall
  /// inside this wait, so the step also requires that the run's coordinators sent no restore
  /// or `Close` for the tab before it was seen gone (`coordinatorITerm2`).
  static let strandedGatewayWait: Duration = .seconds(10)

  /// Which proof this is.
  let kind: Kind
  /// The command's name, `e2e-local` or `e2e-remote`, for the output.
  let name: String
  /// The number of steps, cleanup included.
  let stepCount: Int
  /// tmux on the default server of the host under test.
  let tmux: any HarnessTmux
  /// The helper iTerm2 runs.
  let helperPath: LaunchHelperPath
  /// The iTerm2 client every step shares.
  let client = ITerm2APIClient()
  /// What every coordinator of the run talks to: `client`, with each bury, restore and `Close`
  /// recorded before it is sent, so a detach step can prove that its launch tab left by itself
  /// (`checkGatewayLeft(_:)`). The run's own requests go to `client` directly.
  let coordinatorITerm2: RecordingITerm2Integration
  /// The real launch directory.
  let store = LaunchStore()
  /// Real discovery.
  let discovery = DiscoveryProbe()
  /// The host under test: this Mac, or the remote host by its SSH destination.
  let host: HostConfig
  /// The coordinator's updates, including every launch tab it opened.
  let recorder = UpdateRecorder()
  /// The attachment index every coordinator of the run uses: it asks only connections owned
  /// by this run's launch tabs.
  let index: AttachmentIndex
  /// The coordinator under test.
  let coordinator: AttachCoordinator
  /// The test session's name.
  let sessionName = "muxfinder-test-" + String(format: "%08x", UInt32.random(in: .min ... .max))

  /// A session the Phase 6a steps created, or tried to create, besides the main one: its exact
  /// name, when the attempt started (seconds since 1970), and the record once known. Cleanup
  /// kills each one that still is what was recorded, or finds it by its exact name first.
  struct ExtraSession {
    /// The exact name (it starts with `sessionName`).
    let name: String
    /// When the attempt started.
    let startedAt: Int64
    /// The session as `new-session` reported it, once known.
    var record: CreatedSession?
  }
  /// The extra sessions, in the order they were attempted.
  private var extras: [ExtraSession] = []
  /// `e2e-local`'s private directory under `/private/tmp` (`mfx.XXXXXX`) for the working
  /// directory checks, once made; cleanup removes it.
  private var privateDirectory: String?
  /// The move-here step's plain control client while it may still run; the step's failure path
  /// and cleanup end it (`stopControlClient()`).
  private var controlClient: BackgroundControlClient?

  /// The test session as `new-session` reported it (or as cleanup found it by its name).
  private var created: CreatedSession?
  /// When step 1 started `new-session` (seconds since 1970), so cleanup can find a session
  /// whose creation took effect although its output never arrived; `nil` until then.
  private var creationStartedAt: Int64?
  /// The remote host's `uname -n`, once discovery reported it.
  private var remoteNodeName: String?
  /// `tmux -V` on the host under test, once the header asked.
  private var tmuxVersion: String?
  /// Whether setup turned on the helper's test mode.
  private var markerCreated = false
  /// Whether setup succeeded.
  private var setUp = false
  /// Steps that passed.
  private(set) var passedCount = 0
  /// Observations printed after each step.
  private var notes: [String] = []

  /// Creates the run: `e2e-local` with `tmux` on this Mac, or `e2e-remote` with `tmux` over
  /// ssh to the destination.
  init(kind: Kind, tmux: any HarnessTmux, helperPath: LaunchHelperPath) {
    self.kind = kind
    self.tmux = tmux
    self.helperPath = helperPath
    switch kind {
    case .local:
      name = "e2e-local"
      stepCount = 16
      host = HostConfig(displayName: "This Mac", mode: .local)
    case .remote(let destination):
      name = "e2e-remote"
      stepCount = 17
      host = HostConfig(displayName: "Remote host", mode: .ssh, sshDestination: destination)
    }
    let recorder = self.recorder
    index = AttachmentIndex(
      iTerm2: client,
      configuration: .init(includes: { connection in
        guard let owner = connection.owningSessionID else { return false }
        return recorder.isLaunchTab(owner)
      }))
    coordinatorITerm2 = RecordingITerm2Integration(base: client)
    coordinator = AttachCoordinator(
      iTerm2: coordinatorITerm2, discovery: discovery, store: store, helperPath: helperPath,
      existingAttachments: .index(index), onUpdate: { recorder.record($0) })
  } // End of init(kind:tmux:helperPath:)

  /// Writes `line` to standard output at once (unbuffered, so lines appear as steps end).
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
        + "\(iTerm2Version), \(tmuxVersion ?? "tmux unknown") \(tmux.location), session "
        + "\(sessionName)")
  } // End of func printHeader()

  // MARK: - Steps

  /// Setup, then every step but the last, stopping at the first failure. The last step
  /// (cleanup) is `cleanUp()`.
  func runSteps() async {
    guard await setUpRun() else { return }
    switch kind {
    case .local:
      guard await step(1, "create session", { try await self.createSession() }),
        await step(2, "discover", { try await self.discoverSession() }),
        await step(3, "attach", { try await self.attachAndCheck(self.target, step: 3) }),
        await step(4, "tabs and split", { try await self.checkTabsStep() }),
        await step(5, "focus existing", { try await self.focusExisting() }),
        await step(6, "detach by session", { try await self.detachAndCheck(bySession: true) }),
        await step(7, "reattach", { try await self.reattach(thenDetach: true) }),
        await step(8, "concurrent attaches", { try await self.concurrentAttaches() }),
        await step(9, "stale guard", { try await self.staleGuard() }),
        await step(10, "vanished session", { try await self.vanishedSession() }),
        await step(11, "collision", { try await self.collision() }),
        await step(12, "invalid name", { try await self.invalidName() }),
        await step(13, "missing directory", { try await self.missingDirectory() }),
        await step(14, "new session", { try await self.newSession() }),
        await step(15, "move here", { try await self.moveHereStep() })
      else { return }
    case .remote:
      guard await step(1, "create session", { try await self.createSession() }),
        await step(2, "discover", { try await self.discoverSession() }),
        await step(3, "attach", { try await self.attachAndCheck(self.target, step: 3) }),
        await step(4, "tabs and split", { try await self.checkTabsStep() }),
        await step(5, "detach by session", { try await self.detachAndCheck(bySession: true) }),
        await step(6, "reattach", { try await self.reattach(thenDetach: false) }),
        await step(7, "focus existing", { try await self.focusExisting() }),
        await step(8, "detach", { try await self.detachAndCheck() }),
        await step(9, "stale guard", { try await self.staleGuard() }),
        await step(10, "still waiting", { try await self.stillWaiting() }),
        await step(11, "vanished session", { try await self.vanishedSession() }),
        await step(12, "collision", { try await self.collision() }),
        await step(13, "invalid name", { try await self.invalidName() }),
        await step(14, "missing directory", { try await self.missingDirectory() }),
        await step(15, "new session", { try await self.newSession() }),
        await step(16, "move here", { try await self.moveHereStep() })
      else { return }
    }
  } // End of func runSteps()

  /// Runs one step and prints its PASS or FAIL line (and its notes). Returns whether it passed.
  private func step(
    _ number: Int,
    _ title: String,
    _ body: () async throws -> String
  ) async -> Bool {
    let start = ContinuousClock.now
    notes.removeAll()
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
    let elapsed = milliseconds(ContinuousClock.now - start)
    output("\(passed ? "PASS" : "FAIL") \(number) \(title) (\(elapsed) ms): \(detail)")
    for note in notes { output("  note: \(note)") }
    if passed { passedCount += 1 }
    return passed
  } // End of func step(_:_:_:)

  /// Checks iTerm2's API (and, remotely, that the host answers over ssh) and turns on the
  /// helper's test mode.
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
    do throws(LaunchStoreError) {
      try store.createTestModeMarker()
      markerCreated = true
      _ = try store.takeArgvDigests()
    } catch {
      output("FAIL setup: the launch directory is not usable (\(error.description))")
      return false
    }
    let foreign: Int
    do {
      foreign = try await client.listTmuxConnections().count
    } catch {
      output("FAIL setup: iTerm2's tmux connections could not be listed (\(error))")
      return false
    }
    setUp = true
    output(
      "setup: iTerm2 API connected (protocol \(status.protocolVersion ?? "?")), helper "
        + "\(helperPath.path), helper test mode on; \(foreign) tmux connection(s) this run did "
        + "not open, which its attachment index never asks")
    return true
  } // End of func setUpRun()

  /// The create step: a session with two windows, the first split into two panes, every pane
  /// running `sleep 600`. Records its server, id, creation time and name.
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
    let id = record.sessionID
    let windows = try await tmux.run(["list-windows", "-t", id.rawValue, "-F", "#{window_id}"])
    guard windows.succeeded, let firstWindow = windows.lines.first else {
      throw StepFailure("list-windows failed")
    }
    let split = try await tmux.run(["split-window", "-d", "-t", firstWindow, "sleep", "600"])
    let second = try await tmux.run(["new-window", "-d", "-t", id.rawValue + ":", "sleep", "600"])
    guard split.succeeded, second.succeeded else {
      throw StepFailure("split-window or new-window failed")
    }
    let panes = try await livePanes(id)
    return "\(id) with \(panes.windows) windows, \(panes.count) panes running sleep 600"
  } // End of func createSession()

  /// The session the create step tried to create, found by its exact generated
  /// `muxfinder-test-*` name among the sessions created since `new-session` started (a 2 s
  /// margin for clock steps; 120 s on a remote host, whose clock may differ from this Mac's),
  /// so cleanup can kill a session whose creation took effect although its output was lost (a
  /// failed read, or a signal that cancelled the call). `nil` when creation was never attempted
  /// or no single session qualifies.
  private func recoverCreatedSession() async -> CreatedSession? {
    guard let started = creationStartedAt else { return nil }
    return await recoverSession(named: sessionName, since: started)
  }

  /// The one session named exactly `name` (a `muxfinder-test-*` name this run generated)
  /// created since `started` (with the margins of `recoverCreatedSession()`), or `nil`.
  private func recoverSession(named name: String, since started: Int64) async -> CreatedSession? {
    guard name.hasPrefix(sessionName),
      let listing = try? await tmux.run(["list-sessions", "-F", CreatedSession.format]),
      listing.succeeded
    else { return nil }
    let margin: Int64 = tmux.isLocal ? 2 : 120
    return CreatedSession.find(
      named: name, createdNoEarlierThan: started - margin, in: listing.lines)
  } // End of func recoverSession(named:since:)

  /// The attach target the discover step found.
  private var target: AttachTarget?

  /// The discover step: discovery finds the session with its server, id, creation time, name
  /// and two windows.
  private func discoverSession() async throws -> String {
    let id = try requireSession().sessionID
    let (session, result) = try await discover()
    guard session.name == sessionName, session.windowCount == 2,
      session.attachedClientCount == 0
    else {
      throw StepFailure(
        "unexpected session: \(session.windowCount) windows, "
          + "\(session.attachedClientCount) clients")
    }
    let duration = milliseconds(result.duration)
    notes.append("discovery used \(result.report?.tmuxPath ?? "?") (\(duration) ms)")
    if !tmux.isLocal {
      remoteNodeName = result.report?.nodeName
      notes.append(
        "the remote host's uname -n is \(remoteNodeName ?? "?"); the attachment index matches "
          + "connections by it")
    }
    target = AttachTarget(host: host, session: session)
    return "\(id) found with its name and 2 windows, server pid \(session.key.server.pid), "
      + "\(result.status.sessions.count) session(s) on the server"
  } // End of func discoverSession()

  /// Discovers the host and returns the test session: the session with the recorded id, and
  /// only if its server, creation time and name are the recorded ones too. Every attach target
  /// comes from here, so a session that reused the id after a server restart is never attached.
  private func discover() async throws -> (DiscoveredSession, DiscoveryResult) {
    let created = try requireSession()
    let result = try await discovery.discover(host)
    guard case .ok(let sessions) = result.status else {
      throw StepFailure("discovery reported \(result.status.kind)")
    }
    guard let session = sessions.first(where: { $0.key.sessionID == created.sessionID }) else {
      throw StepFailure("discovery did not report \(created.sessionID)")
    }
    guard created.matches(session) else {
      throw StepFailure(
        "\(created.sessionID) is not the session this run created (its server, creation time "
          + "or name differ); not touching it")
    }
    return (session, result)
  } // End of func discover()

  /// The current attach: its result.
  private var current: AttachResult?

  /// The attach and reattach steps: attaches `target` and checks the result, the states (a
  /// remote attach within its 20 s budget, so never `stillWaiting`) and the helper's argv
  /// digest.
  private func attachAndCheck(_ target: AttachTarget?, step: Int) async throws -> String {
    guard let target else { throw StepFailure("no target from discovery") }
    let result = await coordinator.attach(target)
    current = result
    guard result.isConfirmed, let connectionID = result.connectionID else {
      throw StepFailure(
        "attach ended \(result.state.kind): \(result.failure?.kind ?? "?") "
          + "\(result.failure?.detail ?? "")")
    }
    let states = recorder.stateKinds(of: result.launchID)
    guard states == ["requested", "launched", "confirmed"] else {
      throw StepFailure("states were \(states.joined(separator: " → "))")
    }
    guard case .activated(let tabID) = result.activation else {
      throw StepFailure("activation: \(String(describing: result.activation))")
    }
    guard let counts = result.existingAttachments, counts.mapped == 0, counts.unmapped == 0
    else {
      throw StepFailure(
        "the existing-attachment check found \(String(describing: result.existingAttachments))")
    }
    let argv = try checkArgvDigest(
      for: result.launchID,
      expectedChild: expectedAttachChild(for: target.session, detachesOtherClients: false))
    if step == 3 { notes.append(argv) }
    notes.append(try await checkBuried(result))
    let timings = result.timings
    notes.append(
      "timings from the click: revalidated \(ms(timings.revalidated)) ms, existing attachments "
        + "checked \(ms(timings.checked)) ms (none; \(counts.excluded) connection(s) of others "
        + "not asked), launched \(ms(timings.launched)) ms, connection \(ms(timings.connected)) "
        + "ms, confirmed \(ms(timings.confirmed)) ms, activated \(ms(timings.activated)) ms, "
        + "buried \(ms(timings.buried)) ms")
    return "confirmed on connection \(connectionID) (requested → launched → confirmed), activated "
      + "tab \(tabID), launch tab buried"
  } // End of func attachAndCheck(_:step:)

  /// The focus step: a second attach of the attached session must focus it: state `focused` on the
  /// same connection and launch tab, one of that connection's tabs activated, the check
  /// counting exactly one mapped connection, and nothing opened: the same iTerm2 windows and
  /// tabs before and after (the run's own and every other), the same connections, no new
  /// launch tab and no new argv digest.
  private func focusExisting() async throws -> String {
    guard let attached = current, let connectionID = attached.connectionID,
      let gateway = attached.gatewaySessionID
    else { throw StepFailure("no attachment") }
    let (session, _) = try await discover()
    let target = AttachTarget(host: host, session: session)
    let before = try await client.listSessions()
    let connectionsBefore = try await client.listTmuxConnections()
    let launchesBefore = recorder.launchCount(for: target.key)
    let result = await coordinator.attach(target)
    let after = try await client.listSessions()
    let connectionsAfter = try await client.listTmuxConnections()
    guard result.state == .focused(connectionID: connectionID),
      result.gatewaySessionID == gateway
    else {
      throw StepFailure(
        "the second attach ended \(result.state.kind) (\(result.failure?.kind ?? "-")), not "
          + "focused on connection \(connectionID)")
    }
    let states = recorder.stateKinds(of: result.launchID)
    guard states == ["requested", "focused"] else {
      throw StepFailure("states were \(states.joined(separator: " → "))")
    }
    guard case .activated(let tabID) = result.activation,
      after.tabs(ofTmuxConnection: connectionID).contains(where: { $0.tabID == tabID })
    else { throw StepFailure("activation: \(String(describing: result.activation))") }
    guard let counts = result.existingAttachments, counts.mapped == 1, counts.unmapped == 0
    else {
      throw StepFailure(
        "the existing-attachment check found \(String(describing: result.existingAttachments))")
    }
    let own = ownLayout(before, connectionID: connectionID, gateway: gateway)
    let ownAfter = ownLayout(after, connectionID: connectionID, gateway: gateway)
    let windowIDs = Set(before.windows.compactMap(\.windowID))
    let tabIDs = Set(before.windows.flatMap(\.tabs).compactMap(\.tabID))
    let newWindows = Set(after.windows.compactMap(\.windowID)).subtracting(windowIDs).count
    let newTabs = Set(after.windows.flatMap(\.tabs).compactMap(\.tabID)).subtracting(tabIDs).count
    let digests = try store.takeArgvDigests().count
    guard newWindows == 0, newTabs == 0, own == ownAfter, connectionsAfter == connectionsBefore,
      recorder.launchCount(for: target.key) == launchesBefore, digests == 0
    else {
      throw StepFailure(
        "something opened: \(newWindows) new window(s), \(newTabs) new tab(s), this run's "
          + "windows/tabs \(own.windows)/\(own.tabs) → \(ownAfter.windows)/\(ownAfter.tabs), "
          + "connections \(connectionsBefore.count) → \(connectionsAfter.count), \(digests) "
          + "argv digest(s)")
    }
    notes.append(
      "timings from the call: revalidated \(ms(result.timings.revalidated)) ms, existing "
        + "attachments checked \(ms(result.timings.checked)) ms (1 mapped, 0 unknown, 0 "
        + "ambiguous, 0 nonUTF8, 0 stale, \(counts.excluded) not asked), activated "
        + "\(ms(result.timings.activated)) ms, finished \(ms(result.timings.finished)) ms")
    return "the second attach focused connection \(connectionID) (requested → focused) and "
      + "activated its tab \(tabID); nothing opened: this run's \(own.windows) windows and "
      + "\(own.tabs) tabs, every other window and tab, and the \(connectionsAfter.count) "
      + "connection(s) unchanged, no launch tab, no argv digest"
  } // End of func focusExisting()

  /// The windows and tabs of this run's attachment: the windows holding the connection's tabs
  /// or the launch tab, and their tabs.
  private func ownLayout(
    _ sessions: ITerm2API.ListSessionsResponse,
    connectionID: String,
    gateway: String
  ) -> (windows: Int, tabs: Int) {
    let own = sessions.windows.filter { window in
      window.tabs.contains { tab in
        tab.tmuxConnectionID == connectionID
          || tab.sessions.contains { $0.uniqueIdentifier == gateway }
      }
    }
    return (own.count, own.reduce(0) { $0 + $1.tabs.count })
  } // End of func ownLayout(_:connectionID:gateway:)

  /// Milliseconds of an optional duration, or -1.
  private func ms(_ duration: Duration?) -> Int {
    duration.map(milliseconds) ?? -1
  }

  /// After a confirmed attach (PLAN.md D29, design item 7): the coordinator buried the launch
  /// tab (`burial` is `buried`), and iTerm2 lists it in `buried_sessions` and in no tab within
  /// `buryListing`. Returns a note for the step.
  private func checkBuried(_ result: AttachResult) async throws -> String {
    guard let gateway = result.gatewaySessionID else { throw StepFailure("no launch tab") }
    guard result.burial == .buried else {
      throw StepFailure(
        "the launch tab was not buried: \(result.burial?.kind ?? "no outcome") "
          + "(\(result.burial?.detail ?? "-"))")
    }
    let buried = try await poll(timeout: Self.buryListing) { () -> Bool? in
      GatewayPlace(of: gateway, in: try await self.client.listSessions()) == .buried ? true : nil
    }
    guard buried == true else {
      let place = GatewayPlace(of: gateway, in: try await client.listSessions())
      throw StepFailure(
        "\(Self.buryListing) after the bury the launch tab is \(place.rawValue), not only in "
          + "buried_sessions")
    }
    return "the launch tab is in buried_sessions and in no tab (bury and check done "
      + "\(ms(result.timings.buried)) ms after the call)"
  } // End of func checkBuried(_:)

  /// After a detach, before any cleanup (PLAN.md D29, design item 7): the launch tab `gateway`
  /// must leave both iTerm2's tabs and `buried_sessions` by itself within
  /// `strandedGatewayWait`. A stranded one fails the step, which says where it stayed. "By
  /// itself" is checked, not assumed: once the listing shows the tab gone, the requests the
  /// run's coordinators sent (`coordinatorITerm2`, each recorded before it was sent, so any that
  /// could have removed the tab is there by then) must hold no restore or `Close` that may
  /// have touched it; one that does (the coordinator's recovery of a dead buried tab) fails
  /// the step. Returns how long it took.
  private func checkGatewayLeft(_ gateway: String) async throws -> Duration {
    let start = ContinuousClock.now
    let gone = try await poll(timeout: Self.strandedGatewayWait) { () -> Bool? in
      try await self.client.listSessions().allSessionIDs.contains(gateway) ? nil : true
    }
    let elapsed = ContinuousClock.now - start
    let touched = await coordinatorITerm2.restoresAndCloses(of: gateway)
    let restores = touched.filter { if case .setBuried = $0 { true } else { false } }.count
    let sent =
      "the coordinator sent \(restores) restore(s) and \(touched.count - restores) Close(s) "
      + "that may have touched it"
    guard gone == true else {
      let place = GatewayPlace(of: gateway, in: try await client.listSessions())
      throw StepFailure(
        "the launch tab was stranded "
          + (place == .buried ? "in buried_sessions" : place.rawValue)
          + " \(Self.strandedGatewayWait) after the detach" + (touched.isEmpty ? "" : "; \(sent)"))
    }
    guard touched.isEmpty else {
      throw StepFailure(
        "the launch tab left \(milliseconds(elapsed)) ms after the detach, but not by itself: "
          + sent)
    }
    return elapsed
  } // End of func checkGatewayLeft(_:)

  /// Takes the argv digests and checks the one of `launchID`: three arguments, `attach` and the
  /// launch id; reports whether argv[0] is the helper's path. Its attach child, when the helper
  /// started one, must detach the session's other clients exactly when `detachesOtherClients`
  /// (a move here, PLAN.md D21); with `expectedChild` (argv, argv[0] first) it must exist and
  /// have exactly that argv.
  private func checkArgvDigest(
    for launchID: LaunchToken,
    expectedChild: [String]? = nil,
    detachesOtherClients: Bool = false
  ) throws -> String {
    let digests = try store.takeArgvDigests()
    let mine = digests.filter { $0.launchID == launchID }
    guard mine.count == 1, digests.count == 1, let digest = mine.first else {
      throw StepFailure(
        "expected one argv digest for the launch, found \(mine.count) of "
          + "\(digests.count)")
    }
    let expected = [helperPath.path, "attach", launchID.rawValue].map {
      LaunchArgvDigest.Argument(bytes: Array($0.utf8))
    }
    guard digest.argumentCount == 3,
      Array(digest.arguments.dropFirst()) == Array(expected.dropFirst())
    else {
      throw StepFailure("the helper got \(digest.argumentCount) arguments, not <path> attach <id>")
    }
    if let child = digest.attachChild, child.detachesOtherClients != detachesOtherClients {
      throw StepFailure(
        "the helper's attach child \(child.detachesOtherClients ? "used" : "did not use") "
          + "attach-session -d")
    }
    var childNote = ""
    if let expectedChild, let executable = expectedChild.first {
      let wanted = LaunchArgvDigest.AttachChild(
        executable: executable, arguments: Array(expectedChild.dropFirst()),
        detachesOtherClients: detachesOtherClients)
      guard digest.attachChild == wanted else {
        throw StepFailure(
          "the helper's attach child argv (\(digest.attachChild?.argumentCount ?? 0) arguments) "
            + "is not the expected \(wanted.argumentCount)")
      }
      childNote =
        "; its attach child had exactly the expected \(wanted.argumentCount) arguments, "
        + (detachesOtherClients ? "with attach-session -d" : "without -d")
    }
    let argv0 = digest.arguments[0] == expected[0] ? "the helper's absolute path" : "not the path"
    return "iTerm2 split the Command property into 3 arguments: argv[0] \(argv0), "
      + "argv[1] attach, argv[2] the launch id\(childNote)"
  } // End of func checkArgvDigest(for:expectedChild:detachesOtherClients:)

  /// The argv the helper's attach child must have for `session` (the session the launch
  /// revalidated), written out here rather than taken from the code under test (except the two
  /// static remote scripts): locally `<tmux> -u -CC attach-session [-d] -t <id>` with the tmux
  /// the D5 order finds first, remotely `/usr/bin/ssh -t -o ConnectTimeout=10 -- <destination>
  /// <D3 string>` with `RemoteLaunch.script`, or `RemoteLaunch.moveHereScript` for a move here,
  /// and the five check values.
  private func expectedAttachChild(
    for session: DiscoveredSession,
    detachesOtherClients: Bool
  ) -> [String]? {
    let id = session.key.sessionID.rawValue
    switch kind {
    case .local:
      guard let local = tmux as? TestTmux else { return nil }
      return [local.path, "-u", "-CC", "attach-session"] + (detachesOtherClients ? ["-d"] : [])
        + ["-t", id]
    case .remote(let destination):
      let script = detachesOtherClients ? RemoteLaunch.moveHereScript : RemoteLaunch.script
      let command = ShellQuoting.remoteCommand(
        script: script,
        args: [
          "", id, String(session.key.server.pid), String(session.key.server.startTime),
          String(session.createdAt),
        ])
      return ["/usr/bin/ssh", "-t", "-o", "ConnectTimeout=10", "--", destination, command]
    }
  } // End of func expectedAttachChild(for:detachesOtherClients:)

  /// The tabs and split step.
  private func checkTabsStep() async throws -> String {
    guard let result = current, let connectionID = result.connectionID,
      let gateway = result.gatewaySessionID
    else { throw StepFailure("no attachment") }
    return try await checkTabs(connectionID: connectionID, gateway: gateway, observe: true)
  }

  /// Checks through `ListSessions` that `connectionID` has two tabs, one of them a two-leaf
  /// split, and (with `observe`) notes where iTerm2 put them and what they carry.
  private func checkTabs(
    connectionID: String,
    gateway: String,
    observe: Bool
  ) async throws -> String {
    let settled = try await poll(timeout: .seconds(5)) { () -> ITerm2API.ListSessionsResponse? in
      let sessions = try await self.client.listSessions()
      let leaves = sessions.tabs(ofTmuxConnection: connectionID).map {
        $0.root?.sessions.count ?? 0
      }
      return leaves.sorted() == Self.expectedPaneCounts ? sessions : nil
    }
    guard let sessions = settled else {
      let tabs = try await client.listSessions().tabs(ofTmuxConnection: connectionID)
      throw StepFailure(
        "connection \(connectionID) has \(tabs.count) tabs with "
          + "\(tabs.map { $0.root?.sessions.count ?? 0 }) panes, expected 2 tabs with [1, 2]")
    }
    if observe { notes += placementNotes(sessions, connectionID: connectionID, gateway: gateway) }
    let windowIDs = sessions.tabs(ofTmuxConnection: connectionID).compactMap(\.tmuxWindowID)
    return
      "2 tabs carry connection \(connectionID) (tmux windows \(windowIDs.joined(separator: ", "))); "
      + "one holds a two-pane split, the other one pane"
  } // End of func checkTabs(connectionID:gateway:observe:)

  /// Where iTerm2 put the tmux tabs and the launch tab, and what they carry.
  private func placementNotes(
    _ sessions: ITerm2API.ListSessionsResponse,
    connectionID: String,
    gateway: String
  ) -> [String] {
    var notes: [String] = []
    let tmuxWindows = sessions.windows.filter { window in
      window.tabs.contains { $0.tmuxConnectionID == connectionID }
    }
    let gatewayWindow = sessions.placement(ofSession: gateway)?.window
    let sharesGatewayWindow = tmuxWindows.contains { $0.windowID == gatewayWindow?.windowID }
    let layout =
      tmuxWindows.count == 2 && tmuxWindows.allSatisfy({ $0.tabs.count == 1 })
      ? "each tmux window opened as its own new iTerm2 window (one tab each)"
      : "the tmux tabs are in \(tmuxWindows.count) window(s)"
    notes.append(layout + (sharesGatewayWindow ? ", sharing the launch tab's window" : ""))
    for tab in sessions.tabs(ofTmuxConnection: connectionID) {
      notes.append(
        "tmux tab: tab_id \(tab.tabID ?? "-"), tmux_window_id \(tab.tmuxWindowID ?? "absent"), "
          + "tmux_connection_id \(tab.tmuxConnectionID ?? "absent"), \(tab.root?.sessions.count ?? 0) "
          + "pane(s), split vertical=\(tab.root?.vertical ?? false)")
    }
    if let (window, tab) = sessions.placement(ofSession: gateway) {
      notes.append(
        "launch tab: in a window with \(window.tabs.count) tab(s), tmux_window_id "
          + "\(tab.tmuxWindowID ?? "absent"), tmux_connection_id \(tab.tmuxConnectionID ?? "absent")"
      )
    } else if sessions.buriedSessions.contains(where: { $0.uniqueIdentifier == gateway }) {
      notes.append("launch tab: in buried_sessions (buried once its first tmux tab was activated)")
    } else {
      notes.append("launch tab: not listed")
    }
    return notes
  } // End of func placementNotes(_:connectionID:gateway:)

  /// The detach steps, by session, and by connection (also inside `e2e-local`'s reattach and
  /// concurrent steps): detaches the current attachment and checks that it was clean, that the
  /// buried launch tab left both iTerm2's tabs and `buried_sessions` by itself before any
  /// cleanup (`checkGatewayLeft(_:)`: a stranded one, or one the coordinator restored or
  /// closed, fails the step), and that the session
  /// survived. The coordinator waits
  /// until the launch tab is old enough and sends `detach-client` only if the connection is
  /// still the launch tab's. By session, the coordinator finds the attachment itself (through
  /// the run's attachment index), and must find exactly this one.
  private func detachAndCheck(bySession: Bool = false) async throws -> String {
    guard let result = current, let connectionID = result.connectionID,
      let gateway = result.gatewaySessionID
    else { throw StepFailure("no attachment") }
    let detach: DetachResult
    if bySession {
      let sessionDetach = await coordinator.detach(session: result.key, on: host)
      guard sessionDetach.outcome == .detached, sessionDetach.detaches.count == 1,
        let only = sessionDetach.detaches.first, only.connectionID == connectionID,
        only.gatewaySessionID == gateway
      else {
        throw StepFailure(
          "detach by session ended \(sessionDetach.outcome.rawValue) with "
            + "\(sessionDetach.detaches.count) attachment(s) "
            + "(\(sessionDetach.checkFailure?.kind ?? "no check failure"))")
      }
      notes.append(
        "detach by session found 1 attachment (index: \(sessionDetach.counts?.mapped ?? -1) mapped, "
          + "\(sessionDetach.counts?.unmapped ?? -1) unmapped), checked its identity again and sent "
          + "detach-client bound to the launch tab")
      detach = only
    } else {
      detach = await coordinator.detach(
        connectionID: connectionID, gatewaySessionID: gateway, launchID: result.launchID)
    }
    let ageAtDetach = recorder.age(of: gateway)
    guard detach.commandError != .tmuxConnectionNotOwned else {
      throw StepFailure("connection \(connectionID) is no longer the launch tab's; nothing sent")
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
      try await self.client.listSessions().tabs(ofTmuxConnection: connectionID).isEmpty ? true : nil
    }
    guard tabsGone == true else { throw StepFailure("tmux tabs still open after the detach") }
    let left = try await checkGatewayLeft(gateway)
    notes.append(
      "detach-client was answered \(detach.commandError == nil ? "with OK" : "with an error"); "
        + "the helper exited 0; the launch tab left its tab and buried_sessions by itself "
        + "\(milliseconds(left)) ms after the helper's result; it was \(ageAtDetach) s old when "
        + "the connection had closed and the helper's result had arrived")
    let survival = try await checkSurvives()
    current = nil
    return "connection \(connectionID) closed cleanly, its tabs closed; \(survival)"
  } // End of func detachAndCheck(bySession:)

  /// Checks that the test session still exists as recorded (server, id, creation time, name)
  /// with two windows, three live `sleep` panes and no client.
  private func checkSurvives() async throws -> String {
    let created = try requireSession()
    let id = created.sessionID
    let detached = try await poll(timeout: .seconds(3)) { () -> [String]? in
      let info = try await self.tmux.run([
        "display-message", "-p", "-t", id.rawValue,
        "#{session_windows}\t#{session_attached}\t" + CreatedSession.format,
      ])
      let fields = info.lines.first?.split(
        separator: "\t", maxSplits: 2, omittingEmptySubsequences: false
      ).map(String.init)
      guard info.succeeded, info.lines.count == 1, let fields, fields.count == 3 else { return nil }
      return fields[1] == "0" ? fields : nil
    }
    guard let fields = detached, fields[0] == "2", CreatedSession.parse(fields[2]) == created
    else { throw StepFailure("the session did not survive as it was (or a client stayed)") }
    let panes = try await livePanes(id)
    return "\(id) survived with \(panes.windows) windows and \(panes.count) live sleep panes"
  } // End of func checkSurvives()

  /// Lists `id`'s panes and checks the expected shape: two windows with one and two panes,
  /// every pane alive and running `sleep` (on this Mac, each pane's process also answers
  /// `kill(pid, 0)`).
  private func livePanes(_ id: TmuxSessionID) async throws -> (windows: Int, count: Int) {
    let panes = try await tmux.run([
      "list-panes", "-s", "-t", id.rawValue, "-F",
      "#{window_id}\t#{pane_dead}\t#{pane_current_command}\t#{pane_pid}",
    ])
    guard panes.succeeded else { throw StepFailure("list-panes failed") }
    var perWindow: [String: Int] = [:]
    for line in panes.lines {
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard fields.count == 4, fields[1] == "0", fields[2] == "sleep", let pid = Int32(fields[3]),
        !tmux.isLocal || kill(pid, 0) == 0
      else { throw StepFailure("a pane is not a live sleep") }
      perWindow[fields[0], default: 0] += 1
    }
    guard perWindow.values.sorted() == Self.expectedPaneCounts else {
      throw StepFailure("pane layout per window is \(perWindow.values.sorted())")
    }
    return (perWindow.count, panes.lines.count)
  } // End of func livePanes(_:)

  /// The reattach step: rediscovers (the recorded session only), attaches again, checks the
  /// tabs, and (`thenDetach`, as `e2e-local` does) detaches again; `e2e-remote` leaves the
  /// attachment for its focus step.
  private func reattach(thenDetach: Bool) async throws -> String {
    let (session, _) = try await discover()
    let attached = try await attachAndCheck(AttachTarget(host: host, session: session), step: 7)
    guard let result = current, let connectionID = result.connectionID,
      let gateway = result.gatewaySessionID
    else { throw StepFailure("no attachment") }
    let tabs = try await checkTabs(connectionID: connectionID, gateway: gateway, observe: false)
    guard thenDetach else { return "\(attached); \(tabs)" }
    let detached = try await detachAndCheck()
    return "\(attached); \(tabs); \(detached)"
  } // End of func reattach(thenDetach:)

  /// The concurrent step (`e2e-local`): two concurrent attaches share one launch: one launch
  /// tab (buried, the one new entry of `buried_sessions`), one connection, and the
  /// connection's two tmux tabs as the only new tabs; then detaches.
  private func concurrentAttaches() async throws -> String {
    let (session, _) = try await discover()
    let target = AttachTarget(host: host, session: session)
    let before = try await client.listSessions()
    let connectionsBefore = try await client.listTmuxConnections()
    let launchesBefore = recorder.launchCount(for: target.key)
    async let first = coordinator.attach(target)
    async let second = coordinator.attach(target)
    let results = await [first, second]
    current = results[0]
    guard results.allSatisfy(\.isConfirmed), results[0] == results[1],
      let connectionID = results[0].connectionID, let gateway = results[0].gatewaySessionID
    else {
      throw StepFailure("results: \(results.map { $0.failure?.kind ?? $0.state.kind })")
    }
    let launches = recorder.launchCount(for: target.key) - launchesBefore
    guard launches == 1 else { throw StepFailure("\(launches) launches") }
    _ = try checkArgvDigest(for: results[0].launchID)
    let tabs = try await checkTabs(connectionID: connectionID, gateway: gateway, observe: false)
    let buried = try await checkBuried(results[0])
    let after = try await client.listSessions()
    let connectionsAfter = try await client.listTmuxConnections()
    let newConnections = connectionsAfter.filter { connection in
      !connectionsBefore.contains(connection)
    }
    let oldTabs = Set(before.windows.flatMap(\.tabs).compactMap(\.tabID))
    let newTabs = after.windows.flatMap(\.tabs).filter { tab in
      guard let tabID = tab.tabID else { return false }
      return !oldTabs.contains(tabID)
    }
    // The one launch tab is buried, so every new tab is one of the connection's.
    let newOtherTabs = newTabs.filter { $0.tmuxConnectionID != connectionID }
    let newBuried = after.buriedSessions.filter { summary in
      !before.buriedSessions.contains { $0.uniqueIdentifier == summary.uniqueIdentifier }
    }
    guard newConnections.count == 1, newConnections.first?.owningSessionID == gateway,
      newOtherTabs.isEmpty, newBuried.map(\.uniqueIdentifier) == [gateway]
    else {
      throw StepFailure(
        "\(newConnections.count) new connection(s), \(newOtherTabs.count) new tab(s) of no "
          + "connection, \(newBuried.count) newly buried session(s)")
    }
    let detached = try await detachAndCheck()
    return "both callers got the same confirmed launch: 1 launch tab (buried), 1 new connection, "
      + "\(newTabs.count) tmux tabs; \(tabs); \(buried); \(detached)"
  } // End of func concurrentAttaches()

  /// The stale guard step: a stale launch. Revalidation refuses a stale target before any tab
  /// opens; with discovery reporting the same wrong `session_created`, the request reaches the
  /// helper and its guard refuses it (exit 65; remotely the guard runs on the remote host and
  /// ssh exits 65): `sessionChanged`, and nothing attaches. The stale coordinator uses the run's
  /// filtered attachment index too.
  private func staleGuard() async throws -> String {
    let id = try requireSession().sessionID
    let (session, _) = try await discover()
    var stale = session
    stale.createdAt += 1
    let target = AttachTarget(host: host, session: stale)
    let refused = await coordinator.attach(target)
    guard refused.failure == .sessionChanged, refused.gatewaySessionID == nil else {
      throw StepFailure("revalidation of a stale target ended \(refused.state.kind)")
    }
    let recorder = self.recorder
    let staleCoordinator = AttachCoordinator(
      iTerm2: coordinatorITerm2,
      discovery: StaleCreationDiscovery(base: discovery, sessionID: id, offset: 1),
      store: store, helperPath: helperPath, existingAttachments: .index(index),
      onUpdate: { recorder.record($0) })
    let connectionsBefore = try await client.listTmuxConnections()
    let result = await staleCoordinator.attach(target)
    guard result.failure == .sessionChanged, let gateway = result.gatewaySessionID else {
      throw StepFailure(
        "the stale launch ended \(result.failure?.kind ?? result.state.kind), not sessionChanged "
          + "from the guard")
    }
    _ = try checkArgvDigest(for: result.launchID)
    let connections = try await client.listTmuxConnections()
    let clients = try await tmux.run(["list-clients", "-t", id.rawValue, "-F", "#{client_pid}"])
    guard connections == connectionsBefore,
      !connections.contains(where: { $0.owningSessionID == gateway }),
      clients.succeeded, clients.lines.isEmpty
    else { throw StepFailure("something attached: \(connections.count) connection(s)") }
    notes.append(
      "the guard's refusal reached the coordinator \(ms(result.timings.finished)) ms after the "
        + "attach call (launch tab opened at \(ms(result.timings.launched)) ms)")
    // The helper must keep the tab open with its explanation (it waits for Return); a tab that
    // ended by itself this young would also have raised iTerm2's blocking warning.
    try await Task.sleep(for: .seconds(1))
    guard try await client.listSessions().allSessionIDs.contains(gateway) else {
      throw StepFailure(
        "the refused launch tab closed by itself instead of showing the explanation and waiting "
          + "for Return")
    }
    notes.append("the refused launch tab stays open showing the explanation (the helper waits)")
    try await waitUntilOldEnough([gateway])
    let ageAtClose = recorder.age(of: gateway)
    let closed = try await client.close(.init(target: .sessions([gateway]), force: true))
    let gone = try await poll(timeout: .seconds(5)) { () -> Bool? in
      try await self.client.listSessions().allSessionIDs.contains(gateway) ? nil : true
    }
    guard closed.statuses == [.ok], gone == true else {
      throw StepFailure("closing the refused launch tab failed")
    }
    notes.append(
      "the test closed that tab by the session id iTerm2 reported for it (forced), \(ageAtClose) "
        + "s after it opened")
    _ = try await checkSurvives()
    return "revalidation refused the stale target without a tab; the guard refused the stale "
      + "request (sessionChanged), no connection or tmux client appeared; the refused tab "
      + "stayed open until the test closed it"
  } // End of func staleGuard()

  /// The still-waiting step (`e2e-remote`, PLAN.md D17): attaches the detached test session
  /// through the run's own destination with a coordinator whose requests ask for the helper's
  /// test-only launch delay (`TestLaunchDelayStore`, honored because setup turned test mode
  /// on), so the helper in the launch tab waits `stillWaitingLaunchDelaySeconds` before it
  /// would start ssh: no login, no prompt and no tmux connection meanwhile. Once the 20 s
  /// budget has passed with the launch tab open, the attach must publish `stillWaiting`, never
  /// a success, with no connection for its tab (`checkStillWaiting(_:target:since:before:)`).
  /// The attach runs through `withAwaitedTask`, so whatever ends the step (its end, a failure,
  /// a signal while `CreateTab` is pending) ends it only after the attach has ended and its
  /// launch tab is recorded for cleanup.
  private func stillWaiting() async throws -> String {
    guard case .remote = kind else { throw StepFailure("not a remote run") }
    let (session, _) = try await discover()
    let recorder = self.recorder
    let waitingCoordinator = AttachCoordinator(
      iTerm2: coordinatorITerm2, discovery: discovery,
      store: TestLaunchDelayStore(base: store, seconds: Self.stillWaitingLaunchDelaySeconds),
      helperPath: helperPath, existingAttachments: .index(index),
      onUpdate: { recorder.record($0) })
    let target = AttachTarget(host: host, session: session)
    let connectionsBefore = try await client.listTmuxConnections()
    let mark = recorder.count
    return try await withAwaitedTask(
      { await waitingCoordinator.attach(target) },
      body: { attach in
        try await self.checkStillWaiting(
          attach, target: target, since: mark, before: connectionsBefore)
      })
  } // End of func stillWaiting()

  /// The checks of the still-waiting step while `attach` runs: `stillWaiting` (and nothing
  /// final) among `target`'s updates after the first `mark`, the launch tab open with no
  /// connection (the connections as `connectionsBefore`). The test then closes that launch tab
  /// (it opened it; by the session id iTerm2 reported, forced, at least 10 s after it opened),
  /// the helper ends `interrupted` without having started ssh, and the attach must fail
  /// without ever confirming; the session survives unattached.
  private func checkStillWaiting(
    _ attach: Task<AttachResult, Never>,
    target: AttachTarget,
    since mark: Int,
    before connectionsBefore: [ITerm2API.TmuxConnection]
  ) async throws -> String {
    let recorder = self.recorder
    let budget = AttachCoordinator.Configuration().remoteConfirmationBudget
    let waiting = try await poll(timeout: budget + .seconds(15)) { () -> String? in
      for update in recorder.updates(after: mark) where update.key == target.key {
        switch update.state {
        case .stillWaiting(let gateway): return gateway
        case .failed(let failure):
          throw StepFailure(
            "the attach ended failed (\(failure.kind), \(failure.detail ?? "no detail")) "
              + "instead of waiting")
        case .confirmed, .focused:
          throw StepFailure(
            "the attach ended \(update.state.kind) instead of waiting (was the helper's test "
              + "mode off?)")
        default: continue
        }
      } // End of loop over this attach's updates
      return nil
    }
    guard let gateway = waiting else {
      throw StepFailure("no stillWaiting within \(budget + .seconds(15)) of the attach")
    }
    let waitedFor = recorder.age(of: gateway)
    guard try await client.listSessions().allSessionIDs.contains(gateway) else {
      throw StepFailure("the waiting launch tab is not open")
    }
    let connections = try await client.listTmuxConnections()
    guard connections == connectionsBefore,
      !connections.contains(where: { $0.owningSessionID == gateway })
    else { throw StepFailure("a tmux connection appeared while the helper was waiting") }
    notes.append(
      "the launch tab was \(waitedFor) s old when stillWaiting arrived; its helper was still in "
        + "its \(Self.stillWaitingLaunchDelaySeconds) s test launch delay (ssh not started, no "
        + "prompt) and no connection existed")
    try await waitUntilOldEnough([gateway])
    let ageAtClose = recorder.age(of: gateway)
    let closedAt = ContinuousClock.now
    let closed = try await client.close(.init(target: .sessions([gateway]), force: true))
    guard closed.statuses == [.ok] else { throw StepFailure("closing the waiting tab failed") }
    let result = await Self.value(of: attach, within: .seconds(15))
    let endedAfterClose = milliseconds(ContinuousClock.now - closedAt)
    guard let result else {
      throw StepFailure("the attach did not end within 15 s of closing its launch tab")
    }
    let states = recorder.stateKinds(of: result.launchID)
    guard states == ["requested", "launched", "stillWaiting", "failed"], !result.isAttached,
      result.connectionID == nil, let failure = result.failure,
      let waitedAt = result.timings.stillWaiting, waitedAt >= budget
    else {
      throw StepFailure(
        "states were \(states.joined(separator: " → ")), result \(result.state.kind) "
          + "(\(result.failure?.kind ?? "-"))")
    }
    _ = try checkArgvDigest(for: result.launchID)
    let gone = try await poll(timeout: .seconds(5)) { () -> Bool? in
      try await self.client.listSessions().allSessionIDs.contains(gateway) ? nil : true
    }
    guard gone == true else { throw StepFailure("the waiting launch tab did not close") }
    let helper: String
    if case .helperFailed(let launchFailure) = failure {
      helper = "the helper reported \(launchFailure.kind), exit status \(launchFailure.exitStatus)"
    } else {
      helper = "no helper result"
    }
    notes.append(
      "the test closed that tab (forced) \(ageAtClose) s after it opened; the attach then "
        + "ended \(failure.kind) (\(helper)) \(endedAfterClose) ms after the close, "
        + "\(ms(result.timings.finished)) ms after the call")
    _ = try await checkSurvives()
    return "requested → launched → stillWaiting at \(ms(waitedAt)) ms (budget \(budget)) → "
      + "failed after the test closed the tab; never confirmed, no connection, no login "
      + "attempted; the session survived unattached"
  } // End of func checkStillWaiting(_:target:since:before:)

  /// The value of `task`, or `nil` when it does not finish within `time` (then `task` is
  /// cancelled, and its value is awaited no longer than that takes).
  private static func value(
    of task: Task<AttachResult, Never>,
    within time: Duration
  ) async -> AttachResult? {
    await withTaskGroup(of: AttachResult?.self) { group in
      group.addTask { await task.value }
      group.addTask {
        try? await Task.sleep(for: time)
        task.cancel()
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    } // End of task group racing the task against the time
  } // End of func value(of:within:)

  /// Waits until every launch tab in `gateways` is `launchTabMinimumAge` old, so ending it
  /// does not trigger iTerm2's modal short-lived-session warning.
  private func waitUntilOldEnough(_ gateways: [String]) async throws {
    guard let latest = recorder.latestLaunch(of: gateways) else { return }
    let remaining = latest + Self.launchTabMinimumAge - ContinuousClock.now
    if remaining > .zero { try await Task.sleep(for: remaining) }
  }

  /// The test session as recorded, or a failure if step 1 did not create it.
  private func requireSession() throws -> CreatedSession {
    guard let created else { throw StepFailure("no test session") }
    return created
  }

  // MARK: - Phase 6a: new session and vanished sessions

  /// The vanished-session step: a second session is created (by the harness, `sleep 600`),
  /// discovered, then killed by the harness before the attach. The attach must end
  /// `sessionGone` at revalidation, marked refresh-triggering, with no launch tab, request or
  /// helper, and the `list-sessions` count must be what it was after the kill (nothing
  /// recreated).
  private func vanishedSession() async throws -> String {
    let name = sessionName + "-gone"
    let record = try await createExtra(name)
    let result = try await discovery.discover(host)
    guard case .ok(let sessions) = result.status,
      let session = sessions.first(where: { record.matches($0) })
    else {
      throw StepFailure("discovery did not report \(record.sessionID) (\(result.status.kind))")
    }
    guard try await killExtra(record) else { throw StepFailure("kill-session failed") }
    let countBefore = try await sessionIDs().count
    let connectionsBefore = try await client.listTmuxConnections()
    let target = AttachTarget(host: host, session: session)
    let attached = await coordinator.attach(target)
    let ids = try await sessionIDs()
    let names = try await sessionNames()
    guard attached.failure == .sessionGone, attached.triggersRefresh,
      attached.gatewaySessionID == nil, attached.timings.launched == nil
    else {
      throw StepFailure(
        "the attach ended \(attached.state.kind) (\(attached.failure?.kind ?? "-")), not "
          + "sessionGone without a tab")
    }
    let states = recorder.stateKinds(of: attached.launchID)
    let connectionsAfter = try await client.listTmuxConnections()
    let digests = try store.takeArgvDigests().count
    guard states == ["requested", "failed"], recorder.launchCount(for: target.key) == 0,
      ids.count == countBefore, !ids.contains(record.sessionID.rawValue), !names.contains(name),
      connectionsAfter == connectionsBefore, digests == 0
    else {
      throw StepFailure(
        "states \(states.joined(separator: " → ")), \(ids.count) session(s) (was \(countBefore)), "
          + "\(connectionsAfter.count) connection(s), \(digests) argv digest(s)")
    }
    notes.append(
      "revalidation reported it gone \(ms(attached.timings.finished)) ms after the call; no "
        + "request, launch tab or helper")
    return "\(record.sessionID) was killed after discovery; the attach ended sessionGone "
      + "(refresh-triggering), requested → failed, with no launch tab; list-sessions shows "
      + "\(ids.count) session(s) before and after, nothing recreated"
  } // End of func vanishedSession()

  /// The collision step: creating a session with the main test session's name must fail
  /// `sessionExists` (found by `has-session`) before anything is created or opened, and the
  /// existing session keep its server, id, creation time, name, two windows and live panes.
  private func collision() async throws -> String {
    _ = try requireSession()
    let countBefore = try await sessionIDs().count
    let mark = recorder.count
    let result = await coordinator.createAndAttach(
      NewSessionRequest(host: host, name: sessionName, command: ["sleep", "600"]))
    guard result.creationFailure == .sessionExists(.hasSession), result.created == nil,
      result.attach == nil, result.triggersRefresh
    else {
      throw StepFailure(
        "creating the existing name ended \(result.creationFailure?.kind ?? "without a failure") "
          + "(\(result.creationFailure?.detail ?? "-"))")
    }
    let count = try await sessionIDs().count
    guard recorder.count == mark, count == countBefore else {
      throw StepFailure("something happened: \(recorder.count - mark) update(s), \(count) sessions")
    }
    let survival = try await checkSurvives()
    return "refused with sessionExists (has-session), nothing launched; \(survival); "
      + "list-sessions count \(count) unchanged"
  } // End of func collision()

  /// The invalid-name step: names validation refuses (a `.`, a `:`, a `\`, a line break, only
  /// spaces) fail `invalidName` with no process run (a counting runner under the commands) and
  /// nothing launched or created.
  private func invalidName() async throws -> String {
    let runner = CountingProcessRunner()
    let recorder = self.recorder
    let checker = AttachCoordinator(
      iTerm2: coordinatorITerm2, discovery: discovery, store: store, helperPath: helperPath,
      existingAttachments: .index(index), sessionCreator: TmuxCommands(runner: runner),
      onUpdate: { recorder.record($0) })
    let names = [
      sessionName + "-bad.name", sessionName + "-bad:name", sessionName + #"-bad\name"#,
      sessionName + "-bad\nname", "   ",
    ]
    let mark = recorder.count
    var kinds: [String] = []
    for name in names {
      let result = await checker.createAndAttach(
        NewSessionRequest(host: host, name: name, command: ["sleep", "600"]))
      guard case .invalidName(let rule) = result.creationFailure, result.attach == nil else {
        throw StepFailure("a name was not refused: \(result.creationFailure?.kind ?? "created")")
      }
      kinds.append("\(rule)")
    } // End of loop over the invalid names
    let listed = try await sessionNames()
    guard runner.count == 0, recorder.count == mark,
      !listed.contains(where: { $0.hasPrefix(sessionName + "-bad") })
    else {
      throw StepFailure("\(runner.count) process(es) ran, \(recorder.count - mark) update(s)")
    }
    return "\(names.count) names refused (\(kinds.joined(separator: ", "))) with 0 processes "
      + "run and nothing launched"
  } // End of func invalidName()

  /// The missing-directory step: a working directory with a Unicode name that does not exist
  /// (`e2e-local`: inside the run's private directory; `e2e-remote`: under `~/` on the remote
  /// host, which the run never writes to) fails `directoryMissing`; no session with the new
  /// name exists afterwards, the count is unchanged, nothing launched.
  private func missingDirectory() async throws -> String {
    let name = sessionName + "-nodir"
    let directory: String
    if tmux.isLocal {
      directory = try makePrivateDirectory() + "/missing ünïcödé 日本"
    } else {
      directory = "~/" + sessionName + "-missing ünïcödé 日本"
    }
    extras.append(ExtraSession(name: name, startedAt: Int64(Date().timeIntervalSince1970)))
    let countBefore = try await sessionIDs().count
    let mark = recorder.count
    let result = await coordinator.createAndAttach(
      NewSessionRequest(
        host: host, name: name, workingDirectory: directory, command: ["sleep", "600"]))
    let names = try await sessionNames()
    let count = try await sessionIDs().count
    guard result.creationFailure == .directoryMissing, result.created == nil,
      result.attach == nil, !names.contains(name), count == countBefore, recorder.count == mark
    else {
      throw StepFailure(
        "ended \(result.creationFailure?.kind ?? "created"); \(count) session(s) (was "
          + "\(countBefore)); the name is \(names.contains(name) ? "" : "not ")listed")
    }
    let place = tmux.isLocal ? "in the run's private directory" : "under ~/ on the remote host"
    return "a missing directory with a Unicode name \(place) gave directoryMissing; no session "
      + "created (count \(count) unchanged), nothing launched"
  } // End of func missingDirectory()

  /// The new-session step: `createAndAttach` creates `<session>-new #ü 日本;` (a `#`, Unicode,
  /// spaces, a trailing `;` that tmux would read as a command separator unless escaped)
  /// running `sleep 600` in a directory with spaces and Unicode (`e2e-local`: a real
  /// directory, also with a `#` and a trailing `;`, inside the run's private directory;
  /// `e2e-remote`: `~/Library/Application Support`, which exists there), then attaches it:
  /// confirmed (`requested` → `launched` → `confirmed`), the existing-attachment check skipped
  /// (no connection asked), activated, the launch tab buried (`checkBuried(_:)`), the argv
  /// digest as usual. tmux stored the exact name, the pane runs in the directory
  /// (`#{pane_current_path}`), discovery lists it with one window and one control client; then
  /// it is detached by connection (clean; the launch tab must leave by itself,
  /// `checkGatewayLeft(_:)`) and killed.
  private func newSession() async throws -> String {
    let name = sessionName + "-new #ü 日本;"
    let directory: String
    let expectedPath: String
    if tmux.isLocal {
      let folder = try makePrivateDirectory() + "/dir with spaces ünïcödé 日本 #1;"
      guard mkdir(folder, 0o700) == 0 else { throw StepFailure("could not create the directory") }
      (directory, expectedPath) = (folder, folder)
    } else {
      let home = try await tmux.run(["show-environment", "-g", "HOME"])
      guard home.succeeded, let line = home.lines.first, line.hasPrefix("HOME=/") else {
        throw StepFailure("the remote server's HOME is unknown")
      }
      directory = "~/Library/Application Support"
      expectedPath = String(line.dropFirst(5)) + "/Library/Application Support"
    }
    let index = extras.count
    extras.append(ExtraSession(name: name, startedAt: Int64(Date().timeIntervalSince1970)))
    let callStart = ContinuousClock.now
    let result = await coordinator.createAndAttach(
      NewSessionRequest(
        host: host, name: name, workingDirectory: directory, command: ["sleep", "600"]))
    let callTime = ContinuousClock.now - callStart
    extras[index].record = result.created
    guard let created = result.created, let attach = result.attach else {
      throw StepFailure(
        "creation failed: \(result.creationFailure?.kind ?? "?") "
          + "(\(result.creationFailure?.detail ?? "-"))")
    }
    guard attach.isConfirmed, let connectionID = attach.connectionID,
      let gateway = attach.gatewaySessionID
    else {
      throw StepFailure(
        "attach ended \(attach.state.kind): \(attach.failure?.kind ?? "?") "
          + "\(attach.failure?.detail ?? "")")
    }
    let states = recorder.stateKinds(of: attach.launchID)
    guard states == ["requested", "launched", "confirmed"], attach.existingAttachments == nil,
      case .activated = attach.activation, created.name == name, result.triggersRefresh
    else {
      throw StepFailure(
        "states \(states.joined(separator: " → ")), check \(String(describing: attach.existingAttachments)), "
          + "activation \(String(describing: attach.activation)), name kept: \(created.name == name)"
      )
    }
    _ = try checkArgvDigest(for: attach.launchID)
    notes.append(try await checkBuried(attach))
    let path = try await tmux.run([
      "display-message", "-p", "-t", created.sessionID.rawValue, "#{pane_current_path}",
    ])
    guard path.succeeded, path.lines.count == 1,
      Array(path.lines[0].utf8) == Array(expectedPath.utf8)
    else { throw StepFailure("the pane does not run in the requested directory") }
    let found = try await discovery.discover(host).status.sessions.first { created.matches($0) }
    guard let found, found.windowCount == 1, found.attachedClientCount == 1,
      found.clients.map(\.isControlMode) == [true]
    else { throw StepFailure("discovery does not show the new session with one control client") }
    let creation = callTime - (attach.timings.finished ?? .zero)
    notes.append(
      "createAndAttach took \(milliseconds(callTime)) ms: creation about "
        + "\(milliseconds(creation)) ms, then the attach launched at "
        + "\(ms(attach.timings.launched)) ms, confirmed at \(ms(attach.timings.confirmed)) ms "
        + "and activated at \(ms(attach.timings.activated)) ms of its own time; the "
        + "existing-attachment check did not run")
    let detach = await coordinator.detach(
      connectionID: connectionID, gatewaySessionID: gateway, launchID: attach.launchID)
    guard detach.connectionClosed, detach.isClean else {
      throw StepFailure(
        "detach: closed \(detach.connectionClosed), helper "
          + "\(detach.helperResult.map { "exit \($0.exitStatus)" } ?? "no result")")
    }
    _ = try await checkGatewayLeft(gateway)
    guard try await killExtra(created) else { throw StepFailure("kill-session failed") }
    let place =
      tmux.isLocal ? "a private directory with spaces, Unicode, # and a trailing ;" : directory
    return "\(created.sessionID) created with its exact name (a trailing ; kept) and attached "
      + "(requested → launched "
      + "→ confirmed, no existing-attachment check, launch tab buried); the pane runs in "
      + "\(place); detached cleanly (the launch tab left by itself), then killed"
  } // End of func newSession()

  /// Creates the extra session `name` with the harness's tmux (`sleep 600`, detached) and
  /// records it, so cleanup can kill it.
  private func createExtra(_ name: String) async throws -> CreatedSession {
    let index = extras.count
    extras.append(ExtraSession(name: name, startedAt: Int64(Date().timeIntervalSince1970)))
    let made = try await tmux.run([
      "new-session", "-d", "-P", "-F", CreatedSession.format, "-s", name, "sleep", "600",
    ])
    guard made.succeeded, made.lines.count == 1, let record = CreatedSession.parse(made.lines[0]),
      record.name == name
    else { throw StepFailure("new-session failed: \(made.standardError.prefix(200))") }
    extras[index].record = record
    return record
  } // End of func createExtra(_:)

  /// Kills `record`'s session (one of this run's, its name starting with `sessionName`) only
  /// while it is still exactly that session (server pid, start time and socket, id, creation
  /// time, name): the check and the kill are one tmux command on one server connection
  /// (`CreatedSession.killIfUnchangedArguments`, one ssh invocation remotely), so a server
  /// restarted in between can never lose a session of the user's. Returns `notThisSession`
  /// without running anything for a name that is not this run's, or a record that cannot be
  /// encoded.
  private func killIfUnchanged(_ record: CreatedSession) async throws -> CreatedSession.KillOutcome
  {
    guard record.name.hasPrefix(sessionName), let arguments = record.killIfUnchangedArguments
    else { return .notThisSession }
    let result = try await tmux.run(arguments)
    guard !result.timedOut else { return .failed }
    return CreatedSession.killOutcome(
      exitStatus: result.status, standardOutput: result.standardOutput,
      standardError: result.standardError)
  } // End of func killIfUnchanged(_:)

  /// `killIfUnchanged(_:)` for the steps: whether it killed the session.
  private func killExtra(_ record: CreatedSession) async throws -> Bool {
    try await killIfUnchanged(record) == .killed
  }

  /// The ids `list-sessions` reports now (none when no server runs).
  private func sessionIDs() async throws -> [String] {
    let listed = try await tmux.run(["list-sessions", "-F", "#{session_id}"])
    return listed.succeeded ? listed.lines : []
  }

  /// The names `list-sessions` reports now (none when no server runs).
  private func sessionNames() async throws -> [String] {
    let listed = try await tmux.run(["list-sessions", "-F", "#{session_name}"])
    return listed.succeeded ? listed.lines : []
  }

  /// `e2e-local`'s private directory, `/private/tmp/mfx.XXXXXX` (0700), made on first use.
  private func makePrivateDirectory() throws -> String {
    if let privateDirectory { return privateDirectory }
    var template = Array("/private/tmp/mfx.XXXXXX".utf8CString)
    guard let made = mkdtemp(&template) else {
      throw StepFailure("could not create a private directory")
    }
    let path = String(cString: made)
    privateDirectory = path
    return path
  } // End of func makePrivateDirectory()

  // MARK: - Phase 6b: move here

  /// How long the plain control client may take to show up in `list-clients` (remotely ssh
  /// connects and logs in first).
  static let controlClientAttachBudget: Duration = .seconds(15)
  /// How long the plain control client may take to exit after the move here returned.
  static let controlClientExitBudget: Duration = .seconds(10)
  /// How long after the move here the iTerm2 attachment must still be there.
  static let attachmentHoldTime: Duration = .seconds(2)

  /// The move-here step (PLAN.md D21) on the run's own test session, which no client is
  /// attached to: the harness starts a plain control client on it (`BackgroundControlClient`,
  /// `tmux -u -C attach-session -t '=<name>'`, remotely through noninteractive ssh with no
  /// connection sharing) and checks through `list-clients` that it is the session's one client.
  /// A move here whose confirmation names another key must fail `moveHereNotConfirmed` with
  /// nothing run. The confirmed move here must then be confirmed (`requested` → `launched` →
  /// `confirmed`, activated, the existing-attachment check finding nothing of this run's, the
  /// launch tab buried), its
  /// helper's attach child must have used `attach-session -d` (the argv digest, the exact
  /// argv), the plain client must exit by itself within `controlClientExitBudget` after
  /// printing `%exit`, the session's only client must then be a control client other than the
  /// plain one, and `attachmentHoldTime` later the launch tab must still own its connection,
  /// which must still show the session (the identity check through it) with both tmux tabs.
  /// Last, a clean detach by connection, the session surviving unattached. On any failure the
  /// plain client is ended (`stop()`: its input closed, then its process group ended) before
  /// the step reports; cleanup detaches and kills as usual.
  private func moveHereStep() async throws -> String {
    do {
      return try await moveHere()
    } catch {
      await stopControlClient()
      throw error
    }
  }

  /// The body of `moveHereStep()`.
  private func moveHere() async throws -> String {
    guard current == nil else { throw StepFailure("the test session is still attached") }
    _ = try await checkSurvives()
    let (session, result) = try await discover()
    let id = session.key.sessionID
    let command = tmux.controlClientCommand(attachingTo: sessionName)
    let plain = try BackgroundControlClient.start(
      executable: command.executable, arguments: command.arguments,
      environment: command.environment)
    controlClient = plain
    let plainPID = try await waitForPlainClient(plain, session: id)
    // A confirmation for another key (the same tmux session, another host entry) runs nothing.
    let target = AttachTarget(host: host, session: session)
    let otherKey = SessionKey(hostID: UUID(), server: target.key.server, sessionID: id)
    let mark = recorder.count
    let refused = await coordinator.moveHere(
      target, confirmation: .detachOtherClients(of: otherKey))
    guard refused.failure == .moveHereNotConfirmed, recorder.count == mark,
      try store.takeArgvDigests().isEmpty, try await clientPIDs(of: id) == [plainPID]
    else {
      throw StepFailure(
        "a move here confirmed for another key ended \(refused.failure?.kind ?? "attached")")
    }
    // The confirmed move here.
    let moved = await coordinator.moveHere(
      target, confirmation: .detachOtherClients(of: target.key))
    current = moved
    guard moved.isConfirmed, let connectionID = moved.connectionID,
      let gateway = moved.gatewaySessionID
    else {
      throw StepFailure(
        "the move here ended \(moved.state.kind): \(moved.failure?.kind ?? "?") "
          + "\(moved.failure?.detail ?? "")")
    }
    let states = recorder.stateKinds(of: moved.launchID)
    guard states == ["requested", "launched", "confirmed"], case .activated = moved.activation,
      let counts = moved.existingAttachments, counts.mapped == 0, counts.unmapped == 0
    else {
      throw StepFailure(
        "states \(states.joined(separator: " → ")), activation "
          + "\(String(describing: moved.activation)), check "
          + "\(String(describing: moved.existingAttachments))")
    }
    notes.append(
      try checkArgvDigest(
        for: moved.launchID,
        expectedChild: expectedAttachChild(for: session, detachesOtherClients: true),
        detachesOtherClients: true))
    let exitWait = ContinuousClock.now
    guard let ended = await plain.waitForExit(within: Self.controlClientExitBudget) else {
      throw StepFailure(
        "the plain control client was still running \(Self.controlClientExitBudget) after the "
          + "move here")
    }
    guard plain.sawExitNotification else {
      throw StepFailure("the plain control client ended (\(ended)) without printing %exit")
    }
    notes.append(
      "the plain control client (tmux client pid \(plainPID)) printed %exit and ended by itself "
        + "(\(ended)), \(milliseconds(ContinuousClock.now - exitWait)) ms after the move here "
        + "returned; the move here was confirmed \(ms(moved.timings.confirmed)) ms after the "
        + "call (launched \(ms(moved.timings.launched)) ms)")
    notes.append(try await checkBuried(moved))
    let remaining = try await poll(timeout: .seconds(3)) { () -> [String]? in
      let clients = try await self.clientLines(of: id)
      return clients.count == 1 ? clients : nil
    }
    guard let only = remaining?.first, only.hasSuffix("\t1"), !only.hasPrefix("\(plainPID)\t")
    else {
      throw StepFailure(
        "the session's clients after the move here: \(remaining?.count ?? -1), not one control "
          + "client other than the plain one")
    }
    let survival = try await checkAttachmentHolds(
      connectionID: connectionID, gateway: gateway, key: target.key, host: result,
      client: only)
    controlClient = nil
    let detached = try await detachAndCheck()
    return "a plain control client was attached; a move here confirmed for another key ran "
      + "nothing; the confirmed move here attached through the launch tab with "
      + "attach-session -d (requested → launched → confirmed), the plain client got %exit and "
      + "ended by itself, \(survival); \(detached)"
  } // End of func moveHere()

  /// Waits (within `controlClientAttachBudget`) until `plain` is the only client of the session
  /// `id` (a control client; locally with `plain`'s own pid) and returns its tmux client pid.
  private func waitForPlainClient(
    _ plain: BackgroundControlClient,
    session id: TmuxSessionID
  ) async throws -> String {
    let found = try await poll(timeout: Self.controlClientAttachBudget) { () -> String? in
      guard plain.isRunning else {
        throw StepFailure(
          "the plain control client ended before attaching (\(plain.errorText.prefix(120)))")
      }
      let clients = try await self.clientLines(of: id)
      guard clients.count == 1, let line = clients.first, line.hasSuffix("\t1") else { return nil }
      return String(line.dropLast(2))
    }
    guard let pid = found else {
      throw StepFailure(
        "the plain control client did not attach within \(Self.controlClientAttachBudget)")
    }
    if tmux.isLocal, pid != String(plain.processID) {
      throw StepFailure("the session's one client is not the plain control client")
    }
    return pid
  } // End of func waitForPlainClient(_:session:)

  /// After `attachmentHoldTime`: the launch tab `gateway` still owns `connectionID`, which
  /// still shows `key` on the host discovery reported (the identity check through it, bound to
  /// the launch tab), with the session's two tmux tabs and split; the session's one client is
  /// still `client` (`<pid>\t<control mode>`).
  private func checkAttachmentHolds(
    connectionID: String,
    gateway: String,
    key: SessionKey,
    host result: DiscoveryResult,
    client: String
  ) async throws -> String {
    try await Task.sleep(for: Self.attachmentHoldTime)
    let connections = try await self.client.listTmuxConnections()
    guard
      connections.contains(where: {
        $0.connectionID == connectionID && $0.owningSessionID == gateway
      })
    else { throw StepFailure("the iTerm2 connection was gone \(Self.attachmentHoldTime) later") }
    guard let indexHost = AttachmentIndex.Host(result) else {
      throw StepFailure("discovery gave no report to match the connection against")
    }
    guard
      case .reported(let reported) = try await index.identify(
        connectionID: connectionID, owningSessionID: gateway),
      AttachmentIndex.map(reported, among: [indexHost]) == .mapped(key)
    else { throw StepFailure("the iTerm2 connection no longer shows the session") }
    let tabs = try await checkTabs(connectionID: connectionID, gateway: gateway, observe: false)
    guard try await clientLines(of: key.sessionID) == [client] else {
      throw StepFailure("the session's clients changed after the move here")
    }
    return "\(Self.attachmentHoldTime) later the session's only client was still the "
      + "launch tab's control client and connection \(connectionID) still showed it; \(tabs)"
  } // End of func checkAttachmentHolds(connectionID:gateway:key:host:client:)

  /// `list-clients` of the session `id`: one `<client pid>\t<control mode>` line per client.
  private func clientLines(of id: TmuxSessionID) async throws -> [String] {
    let listed = try await tmux.run([
      "list-clients", "-t", id.rawValue, "-F", "#{client_pid}\t#{client_control_mode}",
    ])
    guard listed.succeeded else { throw StepFailure("list-clients failed") }
    return listed.lines
  }

  /// The client pids of the session `id`.
  private func clientPIDs(of id: TmuxSessionID) async throws -> [String] {
    try await clientLines(of: id).map { String($0.prefix { $0 != "\t" }) }
  }

  /// Ends the plain control client, if one runs (`BackgroundControlClient.stop()`).
  private func stopControlClient() async {
    guard let plain = controlClient else { return }
    controlClient = nil
    await plain.stop()
  }

  // MARK: - Cleanup

  /// The last step: ends the move-here step's plain control client if it still runs, detaches
  /// connections owned by this run's launch tabs, kills the test session (by
  /// id, only if its server, id, creation time and name are the recorded ones, checked in the
  /// same tmux command as the kill; when a signal cut `new-session` short, it is first found by
  /// its exact generated name),
  /// closes this run's launch tabs that are still listed, in a tab or buried (by their recorded
  /// session ids, `closeLeftover(_:)`: every answer and the tab's absence checked, one still
  /// listed restored, then closed again), turns test mode off, and checks nothing is left. Runs
  /// after any failure or signal too, and never cancels itself.
  func cleanUp() async {
    let start = ContinuousClock.now
    var problems: [String] = []
    var actions: [String] = []
    // End the move-here step's plain control client first (its input closed, then its process
    // group), so nothing of this run's stays attached to the test session.
    if controlClient != nil {
      await stopControlClient()
      actions.append("ended the plain control client")
    }
    let gateways = Set(recorder.gatewaySessionIDs)
    // Ending a launch tab too soon makes iTerm2 show a modal warning (see
    // `launchTabMinimumAge`), so wait for the youngest one first. Not cancellable.
    if let latest = recorder.latestLaunch(of: Array(gateways)) {
      let remaining = latest + Self.launchTabMinimumAge - ContinuousClock.now
      if remaining > .zero {
        output("  waiting \(milliseconds(remaining)) ms so no launch tab ends too young")
        try? await Task.sleep(for: remaining)
      }
    }
    // Detach what this run attached and is still attached.
    if let connections = try? await client.listTmuxConnections() {
      for connection in connections {
        guard let owner = connection.owningSessionID, gateways.contains(owner),
          let connectionID = connection.connectionID
        else { continue }
        let detach = await coordinator.detach(connectionID: connectionID, gatewaySessionID: owner)
        actions.append("detached a leftover connection")
        if !detach.connectionClosed { problems.append("a connection did not close") }
      }
    } else if !gateways.isEmpty {
      problems.append("could not list iTerm2's tmux connections")
    }
    // Kill the test session: the one step 1 recorded or, if `new-session` took effect but its
    // output never arrived (a signal cancelled it), the one with the exact generated name.
    if created == nil, let recovered = await recoverCreatedSession() {
      created = recovered
      actions.append("found the test session by its name")
    }
    // Each kill checks the identity in the same tmux command (`killIfUnchanged(_:)`).
    if let created {
      switch try? await killIfUnchanged(created) {
      case .killed: actions.append("killed \(created.sessionID)")
      case .notThisSession: break
      case .failed, nil: problems.append("kill-session failed")
      }
    }
    // Kill the Phase 6a steps' extra sessions the same way: as recorded or, when an attempt's
    // output was lost, found by its exact name among sessions created since the attempt.
    for extra in extras {
      var record = extra.record
      if record == nil,
        let recovered = await recoverSession(named: extra.name, since: extra.startedAt)
      {
        record = recovered
        actions.append("found an extra test session by its name")
      }
      guard let record else { continue }
      switch try? await killIfUnchanged(record) {
      case .killed: actions.append("killed \(record.sessionID)")
      case .notThisSession: break
      case .failed, nil: problems.append("kill-session failed")
      }
    } // End of loop over the extra sessions
    if let privateDirectory {
      do {
        try FileManager.default.removeItem(atPath: privateDirectory)
        actions.append("removed the private directory")
      } catch {
        problems.append("could not remove the private directory")
      }
    }
    // Close this run's launch tabs that are still listed (in a tab or buried), each answer and
    // the tab's absence afterwards checked; one still listed is restored, then closed again.
    let leftovers = await openGateways(gateways)
    for gateway in leftovers {
      let closed = await closeLeftover(gateway)
      actions.append("closed a leftover launch tab (\(closed.details.joined(separator: ", ")))")
      if !closed.gone { problems.append("a launch tab of this run is still listed after Close") }
    } // End of loop over the leftover launch tabs
    // Turn test mode off.
    if markerCreated {
      do throws(LaunchStoreError) {
        _ = try store.takeArgvDigests()
        if try store.removeTestModeMarker() { actions.append("removed the test-mode marker") }
      } catch {
        problems.append("could not remove the test-mode marker")
      }
    }
    problems += await verifyClean(gateways)
    await client.disconnect()
    let elapsed = milliseconds(ContinuousClock.now - start)
    let summary = actions.isEmpty ? "nothing to clean" : actions.joined(separator: ", ")
    if problems.isEmpty, setUp {
      passedCount += 1
      output(
        "PASS \(stepCount) cleanup (\(elapsed) ms): \(summary); no test session, launch tab, "
          + "tmux tab, connection or marker left")
    } else {
      let reason = problems.isEmpty ? "setup failed" : problems.joined(separator: "; ")
      output("FAIL \(stepCount) cleanup (\(elapsed) ms): \(summary); \(reason)")
    }
  } // End of func cleanUp()

  /// Closes this run's launch tab `gateway` (forced, by the session id iTerm2 reported when it
  /// opened it), checking the answer and the tab's absence within 5 s; when it is still
  /// listed, restores it if it is buried (`setBuried(false)`), then closes it again the same
  /// way. Returns whether it is gone and what each request answered (no ids).
  private func closeLeftover(_ gateway: String) async -> (gone: Bool, details: [String]) {
    var details: [String] = []
    if await closeAndCheck(gateway, details: &details) { return (true, details) }
    if let sessions = try? await client.listSessions(),
      GatewayPlace(of: gateway, in: sessions) == .buried
    {
      do {
        try await client.setBuried(false, sessionID: gateway)
        details.append("the restore answered OK")
      } catch let error as ITerm2Error {
        details.append("the restore failed (\(error.kind))")
      } catch {
        details.append("the restore failed")
      }
      _ = try? await poll(timeout: .seconds(5)) { () -> Bool? in
        GatewayPlace(of: gateway, in: try await self.client.listSessions()) == .buried ? nil : true
      }
    }
    return (await closeAndCheck(gateway, details: &details), details)
  } // End of func closeLeftover(_:)

  /// One forced `Close` of `gateway`: appends its answer to `details` and returns whether the
  /// tab is gone (neither in a tab nor buried) within 5 s.
  private func closeAndCheck(_ gateway: String, details: inout [String]) async -> Bool {
    do {
      let response = try await client.close(.init(target: .sessions([gateway]), force: true))
      details.append("Close answered \(E2EBuryRun.names(response.statuses))")
    } catch let error as ITerm2Error {
      details.append("Close failed (\(error.kind))")
    } catch {
      details.append("Close failed")
    }
    let gone = try? await poll(timeout: .seconds(5)) { () -> Bool? in
      try await self.client.listSessions().allSessionIDs.contains(gateway) ? nil : true
    }
    if gone != true { details.append("still listed afterwards") }
    return gone == true
  } // End of func closeAndCheck(_:details:)

  /// The recorded launch tab sessions that iTerm2 still lists (polled briefly, since a tab
  /// closes a moment after its helper exits).
  private func openGateways(_ gateways: Set<String>) async -> [String] {
    guard !gateways.isEmpty else { return [] }
    var open: [String] = []
    for _ in 0..<10 {
      guard let sessions = try? await client.listSessions() else { return [] }
      open = gateways.filter { sessions.allSessionIDs.contains($0) }.sorted()
      if open.isEmpty { return [] }
      try? await Task.sleep(for: .milliseconds(300))
    }
    return open
  } // End of func openGateways(_:)

  /// What is left of this run: the session, launch tabs, tmux tabs, connections, the marker.
  private func verifyClean(_ gateways: Set<String>) async -> [String] {
    var problems: [String] = []
    let names = try? await tmux.run(["list-sessions", "-F", "#{session_name}"])
    if let names, names.succeeded {
      let ours = Set([sessionName] + extras.map(\.name))
      if names.lines.contains(where: ours.contains) {
        problems.append("a test session of this run still exists")
      }
      let others = names.lines.filter { $0.hasPrefix("muxfinder-test-") && !ours.contains($0) }
      if !others.isEmpty {
        output("  note: \(others.count) other muxfinder-test-* session(s) exist (left alone)")
      }
    }
    let gone = try? await poll(timeout: .seconds(5)) { () -> Bool? in
      let sessions = try await self.client.listSessions()
      let connections = try await self.client.listTmuxConnections()
      let tabsLeft = gateways.contains { sessions.allSessionIDs.contains($0) }
      let connectionsLeft = connections.contains { gateways.contains($0.owningSessionID ?? "") }
      return tabsLeft || connectionsLeft ? nil : true
    }
    if gone != true { problems.append("a launch tab or connection of this run is still open") }
    if store.testModeMarkerExists() { problems.append("the test-mode marker is still there") }
    return problems
  } // End of func verifyClean(_:)
}
