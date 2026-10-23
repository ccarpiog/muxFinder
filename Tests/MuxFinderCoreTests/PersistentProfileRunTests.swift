import Foundation
import Testing
import os

@testable import MuxFinderCore

/// tmux for the harness tests: sessions in memory, one server.
actor FakeProfileTmux: ProfileRunTmux {
  /// The sessions by name.
  private(set) var sessions: [String: CreatedSession] = [:]
  /// Every kill asked for.
  private(set) var kills: [CreatedSession] = []
  /// The next session id.
  private var nextID = 3

  /// `at /opt/test/tmux`.
  nonisolated var location: String { "at /opt/test/tmux" }

  /// A fixed version.
  func version() async -> String? { "tmux 9.9-fake" }

  /// Adds a session named `name` (as if the user had one).
  func add(named name: String) {
    sessions[name] = record(named: name)
  }

  /// A record for `name` on the fake server.
  private func record(named name: String) -> CreatedSession {
    defer { nextID += 1 }
    return CreatedSession(
      server: ServerIdentity(
        socketPath: "/private/tmp/tmux-501/default", pid: 4242, startTime: 100),
      sessionID: TmuxSessionID("$\(nextID)")!, createdAt: 200, name: name)
  }

  /// Creates the session.
  func createSession(named name: String) async throws -> CreatedSession {
    let created = record(named: name)
    sessions[name] = created
    return created
  }

  /// The session named `name`.
  func findSession(named name: String) async throws -> CreatedSession? { sessions[name] }

  /// Kills `record`'s session when it is still that one.
  func killIfUnchanged(_ record: CreatedSession) async throws -> CreatedSession.KillOutcome {
    kills.append(record)
    guard sessions[record.name] == record else { return .notThisSession }
    sessions[record.name] = nil
    return .killed
  }
} // End of actor FakeProfileTmux

/// Discovery for the harness tests: the fake tmux's sessions on `Test-Host.local`.
struct FakeProfileDiscovery: HostDiscovering {
  /// The fake tmux.
  let tmux: FakeProfileTmux

  /// The fake tmux's sessions, discovered.
  func discover(_ host: HostConfig) async throws -> DiscoveryResult {
    let sessions = await tmux.sessions.values.map { record in
      DiscoveredSession(
        key: SessionKey(hostID: host.id, server: record.server, sessionID: record.sessionID),
        name: record.name, createdAt: record.createdAt, windowCount: 1, attachedClientCount: 0,
        lastActivityAt: record.createdAt, clients: [])
    }
    return DiscoveryResult(
      hostID: host.id, status: .ok(sessions), report: ProbeReport(nodeName: "Test-Host.local"),
      duration: .milliseconds(5))
  } // End of func discover(_:)
}

/// iTerm2 for the harness tests: it lists the profiles of the `muxFinder.json` in its folder
/// (by GUID), opens a tab for a listed profile name and plays the helper (an argv digest in the
/// launch store, then a tmux connection owned by the tab when `connects`), answers the identity
/// command for the session the tab attached, and closes the connection and the tab on
/// `detach-client`. Everything it was asked is recorded.
actor SimulatedProfileITerm2: ITerm2Integration {
  /// The `DynamicProfiles` folder it reads.
  let folder: URL
  /// The launch store the simulated helper writes its digest to.
  let store: LaunchStore
  /// The tmux whose session the simulated helper attaches.
  let tmux: FakeProfileTmux
  /// Whether the tab's tmux connection appears.
  let connects: Bool
  /// The child argv the simulated helper records (argv[0] first).
  let child: [String]
  /// The open tabs' session ids.
  private(set) var tabs: [String] = []
  /// The tmux connections: id and owner.
  private(set) var connections: [ITerm2API.TmuxConnection] = []
  /// Every tmux command sent, with the owner it was bound to.
  private(set) var commands: [(command: String, owner: String)] = []
  /// Every `CreateTab`.
  private(set) var createdTabs: [ITerm2API.CreateTabRequest] = []
  /// Every forced close.
  private(set) var closed: [ITerm2API.CloseRequest] = []
  /// The GUID filters `ListProfiles` got.
  private(set) var profileFilters: [[String]] = []
  /// Whether a bound `detach-client` goes unanswered (`timedOut`) and detaches nothing.
  private(set) var detachFails = false

  /// Creates the simulation.
  init(folder: URL, store: LaunchStore, tmux: FakeProfileTmux, connects: Bool, child: [String]) {
    self.folder = folder
    self.store = store
    self.tmux = tmux
    self.connects = connects
    self.child = child
  }

  /// From now on, a bound `detach-client` goes unanswered and the connection stays.
  func failDetaches() {
    detachFails = true
  }

  /// A tmux connection owned by the first tab appears (late, after the harness stopped
  /// waiting for one).
  func connectLate() {
    connections.append(
      ITerm2API.TmuxConnection(connectionID: "tmux-late", owningSessionID: tabs.first))
  }

  /// The installed profiles: GUID and name.
  private func installedProfiles() -> [(guid: String, name: String, command: String)] {
    guard
      let data = try? Data(contentsOf: folder.appending(path: PersistentProfiles.fileName)),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let profiles = root["Profiles"] as? [[String: Any]]
    else { return [] }
    return profiles.compactMap { profile in
      guard let guid = profile["Guid"] as? String, let name = profile["Name"] as? String,
        let command = profile["Command"] as? String
      else { return nil }
      return (guid, name, command)
    }
  } // End of func installedProfiles()

  /// Always running.
  func isRunning() async -> Bool { true }

  /// Always connected.
  func status() async -> ITerm2Status {
    ITerm2Status(isRunning: true, socketPresent: true, isConnected: true, protocolVersion: "1.21")
  }

  /// Nothing to do.
  func ensureRunning() async throws {}

  /// The open tabs, each its own window.
  func listSessions() async throws -> ITerm2API.ListSessionsResponse {
    ITerm2API.ListSessionsResponse(
      windows: tabs.map { id in
        ITerm2API.Window(
          windowID: "w-\(id)",
          tabs: [
            ITerm2API.Tab(
              tabID: "t-\(id)",
              root: ITerm2API.SplitTreeNode(
                links: [.session(ITerm2API.SessionSummary(uniqueIdentifier: id))]),
              tmuxWindowID: ITerm2API.Tab.noTmuxWindowID)
          ])
      })
  } // End of func listSessions()

  /// Opens a tab for a listed profile and plays the helper.
  func createTab(_ request: ITerm2API.CreateTabRequest) async throws -> ITerm2API.CreateTabResponse
  {
    createdTabs.append(request)
    guard let profile = installedProfiles().first(where: { $0.name == request.profileName })
    else { throw ITerm2Error.createTabFailed(.invalidProfileName) }
    let sessionID = "session-\(tabs.count + 1)"
    tabs.append(sessionID)
    let argv = profile.command.split(separator: " ").map { Array($0.utf8) }
    var digest = LaunchArgvDigest(argv: argv, helperPID: 777, recordedAt: Date())
    digest.attachChild = LaunchArgvDigest.AttachChild(
      executable: child[0], arguments: Array(child.dropFirst()), detachesOtherClients: false)
    try store.writeArgvDigest(digest)
    if connects {
      connections.append(ITerm2API.TmuxConnection(connectionID: "tmux", owningSessionID: sessionID))
    }
    return ITerm2API.CreateTabResponse(
      status: .ok, windowID: "w-\(sessionID)", tabID: 1, sessionID: sessionID)
  } // End of func createTab(_:)

  /// The connections.
  func listTmuxConnections() async throws -> [ITerm2API.TmuxConnection] { connections }

  /// Unbound commands are never used by the harness.
  func sendTmuxCommand(_ command: String, connectionID: String) async throws -> String {
    Issue.record("an unbound tmux command was sent")
    throw ITerm2Error.tmuxConnectionNotOwned
  }

  /// A bound command: the identity answer for the attached session, or a detach that closes
  /// the connection and the tab.
  func sendTmuxCommand(
    _ command: String,
    connectionID: String,
    ownedBy owningSessionID: String
  ) async throws -> String {
    commands.append((command, owningSessionID))
    guard
      connections.contains(where: {
        $0.connectionID == connectionID && $0.owningSessionID == owningSessionID
      })
    else { throw ITerm2Error.tmuxConnectionNotOwned }
    if command == ConnectionIdentity.detachCommand {
      if detachFails { throw ITerm2Error.timedOut }
      connections.removeAll { $0.owningSessionID == owningSessionID }
      tabs.removeAll { $0 == owningSessionID }
      return ""
    }
    guard let record = try await tmux.findSession(named: PersistentProfileRun.sessionName) else {
      return ""
    }
    let host = "Test-Host.local"
    let socket = record.server.socketPath
    return "1:\(host.utf8.count):\(host):\(record.server.pid):\(record.server.startTime):"
      + "\(socket.utf8.count):\(socket):\(record.sessionID.rawValue)\n"
  } // End of func sendTmuxCommand(_:connectionID:ownedBy:)

  /// Never used by the harness.
  func activate(_ request: ITerm2API.ActivateRequest) async throws {
    Issue.record("activate was called")
  }

  /// Never used by the harness.
  func activateFirstTab(
    ofTmuxConnection connectionID: String,
    ownedBy owningSessionID: String,
    options: ITerm2API.ActivateRequest
  ) async throws -> String? {
    Issue.record("activateFirstTab was called")
    return nil
  }

  /// The installed profiles with the requested GUIDs.
  func listProfiles(properties: [String], guids: [String]) async throws -> [ITerm2API.Profile] {
    profileFilters.append(guids)
    return installedProfiles().filter { guids.isEmpty || guids.contains($0.guid) }.map {
      ITerm2API.Profile(properties: [
        ITerm2API.ProfileProperty(key: "Guid", jsonValue: ITerm2JSON.encode($0.guid)),
        ITerm2API.ProfileProperty(key: "Name", jsonValue: ITerm2JSON.encode($0.name)),
      ])
    }
  } // End of func listProfiles(properties:guids:)

  /// Closes the requested sessions' tabs and their connections.
  func close(_ request: ITerm2API.CloseRequest) async throws -> ITerm2API.CloseResponse {
    closed.append(request)
    if case .sessions(let ids) = request.target {
      tabs.removeAll { ids.contains($0) }
      connections.removeAll { ids.contains($0.owningSessionID ?? "") }
    }
    return ITerm2API.CloseResponse()
  }

  /// Nothing to close.
  func disconnect() async {}
} // End of actor SimulatedProfileITerm2

/// The `e2e-profile` harness (PLAN.md D26) end to end over fakes: a private DynamicProfiles
/// folder with the user's own entries, a fake `defaults`, a private launch directory, an
/// in-memory tmux, simulated iTerm2 and a virtual clock. It never touches the real iTerm2, its
/// folder or preferences, and never runs tmux or ssh.
@Suite("Persistent profile real-run harness")
struct PersistentProfileRunTests {
  /// Everything one run needs.
  struct Fixture {
    /// The harness.
    let run: PersistentProfileRun
    /// The simulated iTerm2.
    let iTerm2: SimulatedProfileITerm2
    /// The fake tmux.
    let tmux: FakeProfileTmux
    /// The launch store.
    let store: LaunchStore
    /// The installer's folder fixture.
    let folder: PersistentProfileInstallerTests.Fixture
    /// The launch store's root.
    let root: URL
    /// The printed lines.
    let lines: OSAllocatedUnfairLock<[String]>
    /// The virtual clock.
    let clock: ManualAttachClock
  }

  /// The helper path the profile runs.
  static let helper = try! LaunchHelperPath(validating: PersistentProfilesTests.helper)

  /// Builds a run of `kind`; `connects: false` makes the tab never get a connection, `child`
  /// is what the simulated helper records (by default the expected argv).
  static func fixture(
    kind: PersistentProfileRun.Kind = .local,
    connects: Bool = true,
    child: [String]? = nil
  ) throws -> Fixture {
    let folder = try PersistentProfileInstallerTests.makeFixture()
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    let tmux = FakeProfileTmux()
    let expected: [String]
    switch kind {
    case .local:
      expected = [
        "/opt/test/tmux", "-u", "-CC", "new-session", "-A", "-s", "muxfinder-test-profile",
      ]
    case .remote(let destination):
      expected = [
        "/usr/bin/ssh", "-t", "-o", "ConnectTimeout=10", "--", destination,
        ShellQuoting.remoteCommand(
          script: ProfileLaunch.remoteScript, args: ["", "muxfinder-test-profile"]),
      ]
    }
    let iTerm2 = SimulatedProfileITerm2(
      folder: folder.directory, store: store, tmux: tmux, connects: connects,
      child: child ?? expected)
    let defaults = ITerm2ProfileSnapshotTests.FakeDefaults(
      output: ITerm2ProfileSnapshotTests.export())
    let snapshotter = ITerm2ProfileSnapshotter(
      directory: folder.directory, runner: defaults, environment: [:])
    let lines = OSAllocatedUnfairLock<[String]>(initialState: [])
    let clock = ManualAttachClock()
    let parts = PersistentProfileRun.Parts(
      iTerm2: iTerm2, installer: folder.installer, snapshot: { try await snapshotter.snapshot() },
      store: store, tmux: tmux, discovery: FakeProfileDiscovery(tmux: tmux), clock: clock,
      output: { line in lines.withLock { $0.append(line) } })
    let run = PersistentProfileRun(
      kind: kind, helper: helper, localTmuxPath: kind == .local ? "/opt/test/tmux" : nil,
      parts: parts)
    return Fixture(
      run: run, iTerm2: iTerm2, tmux: tmux, store: store, folder: folder, root: root,
      lines: lines, clock: clock)
  } // End of func fixture(kind:connects:child:)

  /// Removes the fixture's folders.
  static func remove(_ fixture: Fixture) {
    try? FileManager.default.removeItem(at: fixture.folder.base)
    try? FileManager.default.removeItem(at: fixture.root)
  }

  /// What the run left in its launch directory and DynamicProfiles folder, and its tmux.
  static func leftovers(_ fixture: Fixture) async throws -> [String] {
    var left = try LaunchTestSupport.names(in: fixture.store.directory)
    if LaunchTestSupport.exists(fixture.folder.installer.fileURL) { left.append("muxFinder.json") }
    left += await fixture.tmux.sessions.keys.sorted()
    left += await fixture.iTerm2.tabs
    return left
  }

  /// Locally and remotely: all 14 steps pass; the profile is opened by name in a new window
  /// (no custom command), the tab's connection asked only through its binding (identity, then
  /// detach once the tab is 10 s old), nothing closed by force, the GUID listing filtered to
  /// the run's GUID; afterwards nothing is left and the user's entries are as they were.
  @Test(arguments: [PersistentProfileRun.Kind.local, .remote(destination: "remote.example.test")])
  func passingRun(kind: PersistentProfileRun.Kind) async throws {
    let fixture = try Self.fixture(kind: kind)
    defer { Self.remove(fixture) }
    let before = try PersistentProfileInstallerTests.siblingHashes(of: fixture.folder.directory)
    await fixture.run.runSteps()
    await fixture.run.cleanUp()
    let lines = fixture.lines.withLock { $0 }
    #expect(await fixture.run.passedCount == PersistentProfileRun.stepCount, "\(lines)")
    #expect(lines.filter { $0.hasPrefix("PASS ") }.count == 14)
    let tabs = await fixture.iTerm2.createdTabs
    #expect(tabs.count == 1)
    #expect(tabs.first?.windowID == nil)
    #expect(tabs.first?.customProfileProperties.isEmpty == true)
    #expect(tabs.first?.profileName == fixture.run.profileName)
    let commands = await fixture.iTerm2.commands
    #expect(commands.map(\.command) == [ConnectionIdentity.command, "detach-client"])
    #expect(Set(commands.map(\.owner)) == ["session-1"])
    #expect(await fixture.iTerm2.closed.isEmpty)
    #expect(await fixture.iTerm2.profileFilters.allSatisfy { $0 == [fixture.run.guid] })
    #expect(fixture.clock.elapsed >= .seconds(10))
    #expect(try await Self.leftovers(fixture).isEmpty)
    #expect(
      try PersistentProfileInstallerTests.siblingHashes(of: fixture.folder.directory) == before)
    #expect(await fixture.tmux.kills.count == 1)
  } // End of func passingRun(kind:)

  /// The run refuses to start when `muxFinder.json` exists (the user's): it creates, installs
  /// and opens nothing, and leaves that file exactly as it was.
  @Test func refusesAnExistingProfileFile() async throws {
    let fixture = try Self.fixture()
    defer { Self.remove(fixture) }
    let users = Data(#"{"Profiles": []}"#.utf8)
    try users.write(to: fixture.folder.installer.fileURL)
    await fixture.run.runSteps()
    await fixture.run.cleanUp()
    let lines = fixture.lines.withLock { $0 }
    #expect(lines.first?.hasPrefix("FAIL 1 snapshot before") == true)
    #expect(lines.first?.contains("muxFinder.json exists") == true)
    #expect(try Data(contentsOf: fixture.folder.installer.fileURL) == users)
    #expect(await fixture.tmux.sessions.isEmpty)
    #expect(await fixture.iTerm2.createdTabs.isEmpty)
    #expect(try LaunchTestSupport.names(in: fixture.store.directory).isEmpty)
    #expect(lines.last?.hasPrefix("PASS 14 cleanup") == true)
  } // End of func refusesAnExistingProfileFile()

  /// The run refuses to start when a session named `muxfinder-test-profile` exists (not the
  /// run's) and never kills it.
  @Test func refusesAnExistingSession() async throws {
    let fixture = try Self.fixture()
    defer { Self.remove(fixture) }
    await fixture.tmux.add(named: PersistentProfileRun.sessionName)
    await fixture.run.runSteps()
    await fixture.run.cleanUp()
    #expect(fixture.lines.withLock { $0.first }?.contains("exists already") == true)
    #expect(await fixture.tmux.sessions.count == 1)
    #expect(await fixture.tmux.kills.isEmpty)
    #expect(!LaunchTestSupport.exists(fixture.folder.installer.fileURL))
  }

  /// A tab that never gets a connection fails step 6 after its bounded wait; cleanup closes
  /// only the run's own tab, and only once it is 10 s old, kills the session, removes the
  /// profile file, the test host list and the marker.
  @Test func cleansUpAfterAFailure() async throws {
    let fixture = try Self.fixture(connects: false)
    defer { Self.remove(fixture) }
    let before = try PersistentProfileInstallerTests.siblingHashes(of: fixture.folder.directory)
    await fixture.run.runSteps()
    await fixture.run.cleanUp()
    let lines = fixture.lines.withLock { $0 }
    #expect(lines.contains { $0.hasPrefix("FAIL 6 connection") })
    #expect(lines.last?.hasPrefix("PASS 14 cleanup") == true, "\(lines)")
    #expect(await fixture.run.passedCount == 6)
    let closed = await fixture.iTerm2.closed
    #expect(closed == [ITerm2API.CloseRequest(target: .sessions(["session-1"]), force: true)])
    #expect(fixture.clock.elapsed >= .seconds(15))
    #expect(await fixture.iTerm2.commands.isEmpty)
    #expect(try await Self.leftovers(fixture).isEmpty)
    #expect(
      try PersistentProfileInstallerTests.siblingHashes(of: fixture.folder.directory) == before)
  } // End of func cleansUpAfterAFailure()

  /// A helper whose child is not the expected argv (here the login shell) fails step 6 by the
  /// digest; cleanup detaches through the binding (never a forced close of a tab still
  /// attached) and leaves nothing.
  @Test func digestMismatchFailsAndCleansUp() async throws {
    let fixture = try Self.fixture(child: ["-zsh"])
    defer { Self.remove(fixture) }
    await fixture.run.runSteps()
    await fixture.run.cleanUp()
    let lines = fixture.lines.withLock { $0 }
    #expect(lines.contains { $0.hasPrefix("FAIL 6 connection") && $0.contains("not the expected") })
    #expect(await fixture.iTerm2.commands.map(\.command) == ["detach-client"])
    #expect(await fixture.iTerm2.closed.isEmpty)
    #expect(try await Self.leftovers(fixture).isEmpty)
    #expect(lines.last?.hasPrefix("PASS 14 cleanup") == true)
  } // End of func digestMismatchFailsAndCleansUp()

  /// A cleanup detach that goes unanswered while the connection stays listed is unresolved
  /// (review of Phase 11a): the tab that may hold the tmux gateway is never closed and the
  /// session is not killed; cleanup fails and prints the bound detach and the kill to run by
  /// hand. The profile file, the test host list and the marker are still removed.
  @Test func cleanupLeavesATabWhoseDetachIsUnconfirmed() async throws {
    let fixture = try Self.fixture(child: ["-zsh"])
    defer { Self.remove(fixture) }
    await fixture.run.runSteps()
    await fixture.iTerm2.failDetaches()
    await fixture.run.cleanUp()
    let lines = fixture.lines.withLock { $0 }
    #expect(await fixture.iTerm2.closed.isEmpty, "\(lines)")
    #expect(await fixture.iTerm2.commands.map(\.command) == ["detach-client"])
    #expect(await fixture.iTerm2.tabs == ["session-1"])
    #expect(await fixture.tmux.kills.isEmpty)
    #expect(await fixture.tmux.sessions[PersistentProfileRun.sessionName] != nil)
    let failure = try #require(lines.firstIndex { $0.hasPrefix("FAIL 14 cleanup") })
    #expect(lines[failure].contains("tmux connection(s) tmux"))
    let byHand = Array(lines[(failure + 1)...])
    #expect(
      byHand.contains("  swift run muxfinder-probe detach --connection tmux --gateway session-1"))
    #expect(
      byHand.contains("  tmux kill-session -t '=muxfinder-test-profile'  (tmux at /opt/test/tmux)"))
    #expect(!LaunchTestSupport.exists(fixture.folder.installer.fileURL))
    #expect(try LaunchTestSupport.names(in: fixture.store.directory).isEmpty)
    #expect(await fixture.run.passedCount == 5)
  } // End of func cleanupLeavesATabWhoseDetachIsUnconfirmed()

  /// A connection that appears only after step 6 stopped waiting (review of Phase 11a) is found
  /// at cleanup and detached through the tab's binding; the tab then closes by itself, nothing
  /// is closed by force, and nothing is left.
  @Test func cleanupDetachesAConnectionThatAppearedLate() async throws {
    let fixture = try Self.fixture(connects: false)
    defer { Self.remove(fixture) }
    await fixture.run.runSteps()
    await fixture.iTerm2.connectLate()
    await fixture.run.cleanUp()
    let lines = fixture.lines.withLock { $0 }
    #expect(lines.contains { $0.hasPrefix("FAIL 6 connection") })
    #expect(lines.last?.hasPrefix("PASS 14 cleanup") == true, "\(lines)")
    let commands = await fixture.iTerm2.commands
    #expect(commands.map(\.command) == ["detach-client"])
    #expect(commands.map(\.owner) == ["session-1"])
    #expect(await fixture.iTerm2.closed.isEmpty)
    #expect(try await Self.leftovers(fixture).isEmpty)
  } // End of func cleanupDetachesAConnectionThatAppearedLate()

  /// A changed sibling between the snapshots fails step 8 by name.
  @Test func changedSiblingFailsTheSnapshot() async throws {
    let fixture = try Self.fixture()
    defer { Self.remove(fixture) }
    let snapshot = ITerm2ProfileSnapshot(
      dynamicProfilesDirectory: "/x", directoryExists: true, excludedFileName: "muxFinder.json",
      entries: [.init(name: "mine.json", kind: .file, sha256: "a")], newBookmarks: nil)
    var changed = snapshot
    changed.entries[0].sha256 = "b"
    #expect(changed.differences(from: snapshot) == ["mine.json"])
    #expect(changed != snapshot)
  }
}
