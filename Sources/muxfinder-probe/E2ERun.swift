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

/// One real end-to-end run, `e2e-local` or `e2e-remote` (PLAN.md Phases 4, 5a and 5b): its
/// parts, what it created, and the steps.
///
/// Safety (PLAN.md *Unattended-run rules*): it creates, attaches, detaches and kills only its
/// own `muxfinder-test-<random>` session on the default tmux server of this Mac or of the
/// remote host, and finds it again (to attach, inspect or kill it) only if its server, id,
/// creation time and name are still those `new-session` reported (`CreatedSession`), so a
/// restarted server whose new session reuses the id is never touched. Its attachment index
/// asks only connections owned by launch tabs this run opened
/// (`AttachmentIndex.Configuration.includes`, PLAN.md D16), so no other tmux connection ever
/// gets a command, not even the read-only identity `display-message`. It detaches only
/// connections iTerm2 lists as owned by launch tabs it opened (checked by the coordinator right
/// before `detach-client`), closes only those launch tabs (by the session ids iTerm2 reported
/// when it opened them), and never touches another window, tab, session or tmux session. Every
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
      stepCount = 10
      host = HostConfig(displayName: "This Mac", mode: .local)
    case .remote(let destination):
      name = "e2e-remote"
      stepCount = 11
      host = HostConfig(displayName: "Remote host", mode: .ssh, sshDestination: destination)
    }
    let recorder = self.recorder
    index = AttachmentIndex(
      iTerm2: client,
      configuration: .init(includes: { connection in
        guard let owner = connection.owningSessionID else { return false }
        return recorder.isLaunchTab(owner)
      }))
    coordinator = AttachCoordinator(
      iTerm2: client, discovery: discovery, store: store, helperPath: helperPath,
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
        await step(9, "stale guard", { try await self.staleGuard() })
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
        await step(10, "still waiting", { try await self.stillWaiting() })
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
    guard let started = creationStartedAt, sessionName.hasPrefix("muxfinder-test-"),
      let listing = try? await tmux.run(["list-sessions", "-F", CreatedSession.format]),
      listing.succeeded
    else { return nil }
    let margin: Int64 = tmux.isLocal ? 2 : 120
    return CreatedSession.find(
      named: sessionName, createdNoEarlierThan: started - margin, in: listing.lines)
  } // End of func recoverCreatedSession()

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
    let argv = try checkArgvDigest(for: result.launchID)
    if step == 3 { notes.append(argv) }
    let timings = result.timings
    notes.append(
      "timings from the click: revalidated \(ms(timings.revalidated)) ms, existing attachments "
        + "checked \(ms(timings.checked)) ms (none; \(counts.excluded) connection(s) of others "
        + "not asked), launched \(ms(timings.launched)) ms, connection \(ms(timings.connected)) "
        + "ms, confirmed \(ms(timings.confirmed)) ms, activated \(ms(timings.activated)) ms")
    return "confirmed on connection \(connectionID) (requested → launched → confirmed), activated "
      + "tab \(tabID)"
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

  /// Takes the argv digests and checks the one of `launchID`: three arguments, `attach` and the
  /// launch id; reports whether argv[0] is the helper's path.
  private func checkArgvDigest(for launchID: LaunchToken) throws -> String {
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
    let argv0 = digest.arguments[0] == expected[0] ? "the helper's absolute path" : "not the path"
    return "iTerm2 split the Command property into 3 arguments: argv[0] \(argv0), "
      + "argv[1] attach, argv[2] the launch id"
  } // End of func checkArgvDigest(for:)

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
      notes.append("launch tab: buried by iTerm2 after the connection opened")
    } else {
      notes.append("launch tab: not listed")
    }
    return notes
  } // End of func placementNotes(_:connectionID:gateway:)

  /// The detach steps, by session, and by connection (also inside `e2e-local`'s reattach and
  /// concurrent steps): detaches the current attachment and checks that it was clean and the
  /// session survived. The coordinator waits
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
    let gatewayClosed = try await poll(timeout: .seconds(5)) { () -> Bool? in
      try await self.client.listSessions().allSessionIDs.contains(gateway) ? nil : true
    }
    notes.append(
      "detach-client was answered \(detach.commandError == nil ? "with OK" : "with an error"); "
        + "the helper exited 0; the launch tab "
        + (gatewayClosed == true ? "closed by itself when the helper exited" : "stayed open")
        + "; it was \(ageAtDetach) s old when the connection had closed and the helper's result "
        + "had arrived")
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
  /// tab, one connection, and the connection's two tmux tabs; then detaches.
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
    let newLaunchTabs = newTabs.filter { $0.tmuxConnectionID != connectionID }
    guard newConnections.count == 1, newConnections.first?.owningSessionID == gateway,
      newLaunchTabs.count == 1,
      newLaunchTabs.first?.sessions.contains(where: { $0.uniqueIdentifier == gateway }) == true
    else {
      throw StepFailure(
        "\(newConnections.count) new connection(s), \(newLaunchTabs.count) new launch tab(s)")
    }
    let detached = try await detachAndCheck()
    return "both callers got the same confirmed launch: 1 launch tab, 1 new connection, "
      + "\(newTabs.count - 1) tmux tabs; \(tabs); \(detached)"
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
      iTerm2: client,
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
      iTerm2: client, discovery: discovery,
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

  // MARK: - Cleanup

  /// The last step: detaches connections owned by this run's launch tabs, kills the test session (by
  /// id, after checking that its server, id, creation time and name are the recorded ones;
  /// when a signal cut `new-session` short, it is first found by its exact generated name),
  /// closes this run's launch tabs that are still open (by their recorded session ids), turns
  /// test mode off, and checks nothing is left. Runs after any failure or signal too, and never
  /// cancels itself.
  func cleanUp() async {
    let start = ContinuousClock.now
    var problems: [String] = []
    var actions: [String] = []
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
    if let created {
      let id = created.sessionID
      let found = try? await tmux.run([
        "display-message", "-p", "-t", id.rawValue, CreatedSession.format,
      ])
      if let found, found.succeeded, found.lines.count == 1,
        CreatedSession.parse(found.lines[0]) == created
      {
        let killed = try? await tmux.run(["kill-session", "-t", id.rawValue])
        if killed?.succeeded == true {
          actions.append("killed \(id)")
        } else {
          problems.append("kill-session failed")
        }
      }
    }
    // Close this run's launch tabs that are still open.
    let leftovers = await openGateways(gateways)
    if !leftovers.isEmpty {
      let closed = try? await client.close(.init(target: .sessions(leftovers), force: true))
      actions.append("closed \(leftovers.count) leftover launch tab(s)")
      if closed == nil { problems.append("closing leftover launch tabs failed") }
    }
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
      if names.lines.contains(sessionName) { problems.append("the test session still exists") }
      let others = names.lines.filter { $0.hasPrefix("muxfinder-test-") && $0 != sessionName }
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
