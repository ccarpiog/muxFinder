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
  /// The clock a listing lag sleeps on.
  let clock: (any AttachClock)?
  /// How long the first `ListProfiles` after the file went takes (a slow step 12).
  let listingLagAfterRemoval: Duration
  /// Whether a listing saw the file installed.
  private var listedInstalled = false
  /// Whether the listing lag was spent.
  private var lagged = false

  /// Creates the simulation; with `clock`, the first listing after the file went takes
  /// `listingLagAfterRemoval` of its time.
  init(
    folder: URL,
    store: LaunchStore,
    tmux: FakeProfileTmux,
    connects: Bool,
    child: [String],
    clock: (any AttachClock)? = nil,
    listingLagAfterRemoval: Duration = .zero
  ) {
    self.folder = folder
    self.store = store
    self.tmux = tmux
    self.connects = connects
    self.child = child
    self.clock = clock
    self.listingLagAfterRemoval = listingLagAfterRemoval
  } // End of init(folder:store:tmux:connects:child:clock:listingLagAfterRemoval:)

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

  /// The installed profiles with the requested GUIDs; the first listing after the file went
  /// takes `listingLagAfterRemoval`.
  func listProfiles(properties: [String], guids: [String]) async throws -> [ITerm2API.Profile] {
    profileFilters.append(guids)
    let installed = installedProfiles()
    if !installed.isEmpty {
      listedInstalled = true
    } else if listedInstalled, !lagged, let clock, listingLagAfterRemoval > .zero {
      lagged = true
      try await clock.sleep(for: listingLagAfterRemoval)
    }
    return installed.filter { guids.isEmpty || guids.contains($0.guid) }.map {
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

/// `defaults export` for the harness tests, playing what iTerm2 3.7.6 was seen doing with its
/// saved `New Bookmarks` (PLAN.md D26): the user's two profiles, and while the stand-in
/// folder's `muxFinder.json` holds profiles, iTerm2's copy of each (every key the file gives
/// it, keys iTerm2 fills in, and `Dynamic Profile Filename` naming the file) between them;
/// once the file is gone, the copies stay for `dropAfter` of virtual time from the first
/// export that saw it gone (`nil`: forever). `change` renames the user's first profile while
/// the file is installed or once it was removed; `variation` adds what only looks like a copy;
/// `exportDurationAfterRemoval` makes each export once the file is gone take that long (cut at
/// the request's timeout, as a timed-out run, when `honorsTimeout`). Every request's timeout
/// is recorded.
final class MirroringDefaults: ProcessRunner {
  /// When the user's first profile is renamed.
  enum UserChange: Sendable {
    /// Never.
    case none
    /// While `muxFinder.json` is installed.
    case whileInstalled
    /// Once it was installed and is gone.
    case afterRemoval
  }

  /// What `New Bookmarks` holds besides the user's profiles and iTerm2's copies.
  enum Variation: Sendable {
    /// Nothing.
    case none
    /// While the file is installed, iTerm2's copy has another `Command` than the file.
    case changedCopy
    /// While the file is installed, one more entry beside the copy: the copy's keys with
    /// `guid` (the copy's own when `nil`) naming `file` (the owned file when `nil`).
    case lookAlike(guid: String?, file: String?)
    /// From the first export on, an earlier run's copy (another generated GUID naming the
    /// owned file), gone `dropAfter` after that export (`nil`: never).
    case staleCopy(dropAfter: Duration?)
  }

  /// One recorded request.
  struct Export: Sendable {
    /// Whether the file had been installed and was gone.
    var afterRemoval: Bool
    /// The request's timeout.
    var timeout: Duration?
  }

  /// Mutable state.
  struct State: Sendable {
    /// The `muxFinder.json` bytes iTerm2's copies come from.
    var copied: Data?
    /// When an export first saw the file gone while copies remained.
    var goneSince: ContinuousClock.Instant?
    /// When the first export ran.
    var firstExportAt: ContinuousClock.Instant?
    /// Whether an export saw the file installed.
    var sawInstalled = false
    /// The most copies (and look-alikes) one export held.
    var mostCopies = 0
    /// Every export.
    var exports: [Export] = []
  }

  /// The GUID of the earlier run's copy (`Variation.staleCopy`).
  static let staleGUID = "muxfinder-persistent-00000000-0000-4000-8000-0000000000aa"

  /// The stand-in `DynamicProfiles` folder.
  let folder: URL
  /// The virtual clock.
  let clock: any AttachClock
  /// How long the copies outlive the file; `nil` for ever.
  let dropAfter: Duration?
  /// The user's change.
  let change: UserChange
  /// The look-alike, if any.
  let variation: Variation
  /// How long an export takes once the file is gone.
  let exportDurationAfterRemoval: Duration
  /// Whether such an export ends at its request's timeout (timed out) when that is shorter.
  let honorsTimeout: Bool
  /// The state.
  let state = OSAllocatedUnfairLock(initialState: State())

  /// Creates the fake.
  init(
    folder: URL,
    clock: any AttachClock,
    dropAfter: Duration?,
    change: UserChange,
    variation: Variation = .none,
    exportDurationAfterRemoval: Duration = .zero,
    honorsTimeout: Bool = true
  ) {
    self.folder = folder
    self.clock = clock
    self.dropAfter = dropAfter
    self.change = change
    self.variation = variation
    self.exportDurationAfterRemoval = exportDurationAfterRemoval
    self.honorsTimeout = honorsTimeout
  } // End of init(folder:clock:dropAfter:change:…)

  /// The profiles of a `muxFinder.json` document.
  static func profiles(in document: Data?) -> [[String: Any]] {
    guard let document,
      let root = try? JSONSerialization.jsonObject(with: document) as? [String: Any],
      let profiles = root["Profiles"] as? [[String: Any]]
    else { return [] }
    return profiles
  }

  /// The export as iTerm2 would have it now.
  func run(_ request: ProcessRequest) async throws -> ProcessResult {
    let installed = try? Data(contentsOf: folder.appending(path: PersistentProfiles.fileName))
    let (now, dropAfter, change, variation) = (clock.now(), dropAfter, change, variation)
    let (copied, renamed, afterRemoval, stale) = state.withLock {
      state -> (Data?, Bool, Bool, Bool) in
      let firstExportAt = state.firstExportAt ?? now
      state.firstExportAt = firstExportAt
      if let installed {
        (state.copied, state.goneSince, state.sawInstalled) = (installed, nil, true)
      } else if state.copied != nil {
        let since = state.goneSince ?? now
        state.goneSince = since
        if let dropAfter, now - since >= dropAfter { state.copied = nil }
      }
      let afterRemoval = installed == nil && state.sawInstalled
      state.exports.append(Export(afterRemoval: afterRemoval, timeout: request.timeout))
      var stale = false
      var extra = 0
      switch variation {
      case .staleCopy(let dropAfter): stale = dropAfter.map { now - firstExportAt < $0 } ?? true
      case .lookAlike: extra = installed == nil ? 0 : 1
      default: break
      }
      let copies = Self.profiles(in: state.copied).count + (stale ? 1 : 0) + extra
      state.mostCopies = max(state.mostCopies, copies)
      switch change {
      case .none: return (state.copied, false, afterRemoval, stale)
      case .whileInstalled: return (state.copied, installed != nil, afterRemoval, stale)
      case .afterRemoval: return (state.copied, afterRemoval, afterRemoval, stale)
      }
    } // End of the locked update
    if afterRemoval, exportDurationAfterRemoval > .zero {
      if honorsTimeout, let timeout = request.timeout, timeout < exportDurationAfterRemoval {
        try await clock.sleep(for: timeout)
        return ProcessResult(processID: 56, termination: .signaled(SIGTERM), timedOut: true)
      }
      try await clock.sleep(for: exportDurationAfterRemoval)
    }
    let fileKey = ITerm2ProfileSnapshotter.dynamicProfileFilenameKey
    let file = folder.appending(path: PersistentProfiles.fileName).path(percentEncoded: false)
    var mirrored: [Any] = Self.profiles(in: copied).map { profile -> [String: Any] in
      var copy = profile
      copy[fileKey] = file
      copy["Columns"] = 80
      copy["Rows"] = 25
      if installed != nil, case .changedCopy = variation { copy["Command"] = "/bin/zsh" }
      return copy
    }
    if installed != nil, case .lookAlike(let guid, let other) = variation,
      var lookAlike = mirrored.first as? [String: Any]
    {
      lookAlike["Guid"] = guid ?? lookAlike["Guid"]
      lookAlike[fileKey] = other ?? file
      mirrored.append(lookAlike)
    }
    if stale {
      mirrored.insert(
        [
          "Guid": Self.staleGUID, "Name": "Persistent work \u{2013} Earlier", "Tags": ["muxFinder"],
          fileKey: file,
        ] as [String: Any], at: 0)
    }
    let user: [Any] = [
      ["Name": renamed ? "Renamed" : "Default", "Guid": "guid-1", "Columns": 80] as [String: Any],
      ["Name": "Second", "Guid": "guid-2"],
    ]
    let data = try ITerm2ProfileSnapshotTests.export(bookmarks: [user[0]] + mirrored + [user[1]])
    return ProcessResult(processID: 56, termination: .exited(0), standardOutput: data)
  } // End of func run(_:)

  /// The timeouts of the exports taken once the file was gone.
  var timeoutsAfterRemoval: [Duration?] {
    state.withLock { $0.exports.filter(\.afterRemoval).map(\.timeout) }
  }
} // End of class MirroringDefaults

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
    /// The `defaults` that plays iTerm2's copies, when the run uses one.
    let mirroring: MirroringDefaults?
  } // End of struct Fixture

  /// How the fixture's `defaults` plays iTerm2's copies of muxFinder's profile.
  struct Mirroring {
    /// How long the copy outlives the file (`nil`: forever).
    var dropAfter: Duration?
    /// The user's change.
    var change: MirroringDefaults.UserChange = .none
    /// What only looks like a copy.
    var variation: MirroringDefaults.Variation = .none
    /// How long an export takes once the file is gone.
    var exportDurationAfterRemoval: Duration = .zero
    /// Whether such an export ends at its request's timeout.
    var honorsTimeout = true
  }

  /// The helper path the profile runs.
  static let helper = try! LaunchHelperPath(validating: PersistentProfilesTests.helper)

  /// Builds a run of `kind`; `connects: false` makes the tab never get a connection, `child`
  /// is what the simulated helper records (by default the expected argv), `mirroring` makes
  /// `defaults` play iTerm2's copies of the installed profile (by default a fixed export),
  /// `listingLagAfterRemoval` makes step 12's first listing take that long.
  static func fixture(
    kind: PersistentProfileRun.Kind = .local,
    connects: Bool = true,
    child: [String]? = nil,
    mirroring: Mirroring? = nil,
    listingLagAfterRemoval: Duration = .zero
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
    let clock = ManualAttachClock()
    let iTerm2 = SimulatedProfileITerm2(
      folder: folder.directory, store: store, tmux: tmux, connects: connects,
      child: child ?? expected, clock: clock, listingLagAfterRemoval: listingLagAfterRemoval)
    let mirroringDefaults = mirroring.map {
      MirroringDefaults(
        folder: folder.directory, clock: clock, dropAfter: $0.dropAfter, change: $0.change,
        variation: $0.variation, exportDurationAfterRemoval: $0.exportDurationAfterRemoval,
        honorsTimeout: $0.honorsTimeout)
    }
    let defaults: any ProcessRunner =
      mirroringDefaults
      ?? ITerm2ProfileSnapshotTests.FakeDefaults(output: ITerm2ProfileSnapshotTests.export())
    let snapshotter = ITerm2ProfileSnapshotter(
      directory: folder.directory, runner: defaults, environment: [:])
    let lines = OSAllocatedUnfairLock<[String]>(initialState: [])
    let parts = PersistentProfileRun.Parts(
      iTerm2: iTerm2, installer: folder.installer, snapshot: { try await snapshotter.snapshot($0) },
      store: store, tmux: tmux, discovery: FakeProfileDiscovery(tmux: tmux), clock: clock,
      output: { line in lines.withLock { $0.append(line) } })
    let run = PersistentProfileRun(
      kind: kind, helper: helper, localTmuxPath: kind == .local ? "/opt/test/tmux" : nil,
      parts: parts)
    return Fixture(
      run: run, iTerm2: iTerm2, tmux: tmux, store: store, folder: folder, root: root,
      lines: lines, clock: clock, mirroring: mirroringDefaults)
  } // End of func fixture(kind:connects:child:mirroring:)

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

  /// The note step 8 prints with one copy of the profile in `New Bookmarks`.
  static let installedNote =
    "  note: New Bookmarks: 1 mirrored muxFinder entry left out of the hash (iTerm2 copies "
    + "loaded dynamic profiles there)"
  /// The note step 13 prints when iTerm2 dropped the copy 12 s after the removal.
  static let droppedNote =
    "  note: iTerm2 dropped its copy of the profile from New Bookmarks 12000 ms after the file "
    + "was removed"

  /// iTerm2 copies the loaded profile into its saved `New Bookmarks` and drops the copy some
  /// seconds after the file goes (seen in iTerm2 3.7.6, Phase 11b's first real runs; here
  /// 12 s): step 8 leaves the copy out of the hash and counts it, step 13 waits for it to go,
  /// reports how long after the removal that was and compares; all 14 steps pass.
  @Test(arguments: [PersistentProfileRun.Kind.local, .remote(destination: "remote.example.test")])
  func mirroredProfileIsLeftOutAndAwaited(kind: PersistentProfileRun.Kind) async throws {
    let fixture = try Self.fixture(kind: kind, mirroring: Mirroring(dropAfter: .seconds(12)))
    defer { Self.remove(fixture) }
    await fixture.run.runSteps()
    await fixture.run.cleanUp()
    let lines = fixture.lines.withLock { $0 }
    #expect(await fixture.run.passedCount == PersistentProfileRun.stepCount, "\(lines)")
    #expect(fixture.mirroring?.state.withLock { $0.mostCopies } == 1)
    let installed = try #require(lines.firstIndex { $0.hasPrefix("PASS 8 snapshot installed") })
    #expect(lines[installed + 1] == Self.installedNote)
    let after = try #require(lines.firstIndex { $0.hasPrefix("PASS 13 snapshot after") })
    #expect(lines[after].hasSuffix("held no muxFinder copy, 12000 ms after the removal"))
    #expect(lines[after + 1] == Self.droppedNote)
    #expect(try await Self.leftovers(fixture).isEmpty)
  } // End of func mirroredProfileIsLeftOutAndAwaited(kind:)

  /// A copy iTerm2 never drops fails step 13 after its 30 s of polling, saying the file is
  /// gone and the other profiles hash as before; cleanup still passes and leaves nothing.
  @Test func mirrorThatStaysFailsStepThirteen() async throws {
    let fixture = try Self.fixture(mirroring: Mirroring(dropAfter: nil))
    defer { Self.remove(fixture) }
    await fixture.run.runSteps()
    let beforeCleanup = fixture.clock.elapsed
    await fixture.run.cleanUp()
    let lines = fixture.lines.withLock { $0 }
    let failure = try #require(lines.first { $0.hasPrefix("FAIL 13 snapshot after") }, "\(lines)")
    #expect(failure.hasPrefix("FAIL 13 snapshot after (30000 ms): "))
    #expect(failure.hasSuffix(Self.stillHeld))
    #expect(beforeCleanup >= .seconds(40))
    #expect(lines.last?.hasPrefix("PASS 14 cleanup") == true)
    #expect(await fixture.run.passedCount == 13)
    #expect(try await Self.leftovers(fixture).isEmpty)
  } // End of func mirrorThatStaysFailsStepThirteen()

  /// The end of step 13's failure when iTerm2 keeps its copy past the deadline.
  static let stillHeld =
    "iTerm2 still holds 1 mirrored muxFinder entry in New Bookmarks 30.0 seconds after "
    + "muxFinder.json was removed (the other profiles hash as before; the file is gone, nothing "
    + "else to clean up)"

  /// Step 13's deadline is absolute, counted from step 11's removal (review of Phase 11b): when
  /// step 12 took 25 s, a copy that never goes fails step 13 after the 5 s left, not after a
  /// fresh 30 s; each `defaults export` gets at most what is left (5 s, then 4.5 s … down to
  /// the last 0.5 s) instead of its usual 20 s.
  @Test func mirrorDeadlineCountsFromTheRemoval() async throws {
    let fixture = try Self.fixture(
      mirroring: Mirroring(dropAfter: nil), listingLagAfterRemoval: .seconds(25))
    defer { Self.remove(fixture) }
    await fixture.run.runSteps()
    await fixture.run.cleanUp()
    let lines = fixture.lines.withLock { $0 }
    #expect(lines.contains { $0.hasPrefix("PASS 12 profile gone (25000 ms)") }, "\(lines)")
    let failure = try #require(lines.first { $0.hasPrefix("FAIL 13 snapshot after") }, "\(lines)")
    #expect(failure.hasPrefix("FAIL 13 snapshot after (5000 ms): "))
    #expect(failure.hasSuffix(Self.stillHeld))
    let timeouts = try #require(fixture.mirroring?.timeoutsAfterRemoval)
    #expect(timeouts == (1...10).reversed().map { .milliseconds($0 * 500) })
    #expect(lines.last?.hasPrefix("PASS 14 cleanup") == true)
    #expect(await fixture.run.passedCount == 13)
    #expect(try await Self.leftovers(fixture).isEmpty)
  } // End of func mirrorDeadlineCountsFromTheRemoval()

  /// A snapshot running at the deadline does not count (review of Phase 11b). With 5 s left
  /// after a slow step 12 and an export that takes 6 s (iTerm2 having dropped its copy): an
  /// export cut at its 5 s timeout fails step 13 as out of time, not as a `defaults` failure;
  /// one that overruns its timeout and ends clean after the deadline is not taken as success.
  @Test(arguments: [true, false])
  func snapshotEndingAfterTheDeadlineDoesNotCount(honorsTimeout: Bool) async throws {
    let fixture = try Self.fixture(
      mirroring: Mirroring(
        dropAfter: .zero, exportDurationAfterRemoval: .seconds(6), honorsTimeout: honorsTimeout),
      listingLagAfterRemoval: .seconds(25))
    defer { Self.remove(fixture) }
    await fixture.run.runSteps()
    await fixture.run.cleanUp()
    let lines = fixture.lines.withLock { $0 }
    let failure = try #require(lines.first { $0.hasPrefix("FAIL 13 snapshot after") }, "\(lines)")
    #expect(failure.hasPrefix("FAIL 13 snapshot after (\(honorsTimeout ? 5000 : 6000) ms): "))
    #expect(
      failure.hasSuffix(
        "no snapshot of New Bookmarks ended within 30.0 seconds of muxFinder.json's removal (the "
          + "last one ended after that and was not counted; the file is gone, nothing else to "
          + "clean up)"))
    #expect(fixture.mirroring?.timeoutsAfterRemoval == [.seconds(5)])
    #expect(lines.last?.hasPrefix("PASS 14 cleanup") == true)
    #expect(await fixture.run.passedCount == 13)
    #expect(try await Self.leftovers(fixture).isEmpty)
  } // End of func snapshotEndingAfterTheDeadlineDoesNotCount(honorsTimeout:)

  /// Only iTerm2's unchanged copy of the run's own profile is left out at step 8 (review of
  /// Phase 11b): a copy whose written `Command` changed, a look-alike GUID naming the owned
  /// file, or the run's GUID naming another folder's `muxFinder.json` is hashed, so step 8
  /// fails on `New Bookmarks` with a note giving the hashed counts; cleanup leaves nothing.
  @Test(arguments: [
    MirroringDefaults.Variation.changedCopy,
    .lookAlike(guid: "muxfinder-persistent-custom", file: nil),
    .lookAlike(guid: nil, file: "/other/DynamicProfiles/muxFinder.json"),
    .lookAlike(guid: MirroringDefaults.staleGUID, file: nil),
  ])
  func onlyTheRunsUnchangedCopyIsLeftOut(variation: MirroringDefaults.Variation) async throws {
    let fixture = try Self.fixture(
      mirroring: Mirroring(dropAfter: .seconds(1), variation: variation))
    defer { Self.remove(fixture) }
    await fixture.run.runSteps()
    await fixture.run.cleanUp()
    let lines = fixture.lines.withLock { $0 }
    let failure = try #require(
      lines.firstIndex { $0.hasPrefix("FAIL 8 snapshot installed") }, "\(lines)")
    #expect(lines[failure].hasSuffix("iTerm2's other profiles changed: New Bookmarks"))
    var leftOut = "1 mirrored muxFinder entry"
    if case .changedCopy = variation { leftOut = "0 mirrored muxFinder entries" }
    #expect(
      lines[failure + 1]
        == "  note: New Bookmarks: \(leftOut) left out of the hash (iTerm2 copies loaded dynamic "
        + "profiles there)")
    #expect(
      lines[failure + 2] == "  note: New Bookmarks: 3 profiles hashed now, 2 in the first snapshot")
    #expect(lines.last?.hasPrefix("PASS 14 cleanup") == true)
    #expect(await fixture.run.passedCount == 8)
    #expect(try await Self.leftovers(fixture).isEmpty)
  } // End of func onlyTheRunsUnchangedCopyIsLeftOut(variation:)

  /// A copy of a muxFinder profile in `New Bookmarks` before the run, while no `muxFinder.json`
  /// exists, is unexplained (review of Phase 11b): one iTerm2 drops within step 1's 5 s is
  /// waited for, noted and never part of the baseline (all 14 steps pass); one that stays
  /// fails step 1 after those 5 s, before anything is created.
  @Test(arguments: [Duration?.some(.seconds(2)), nil])
  func baselineCopyIsWaitedForOrRefused(dropAfter: Duration?) async throws {
    let fixture = try Self.fixture(
      mirroring: Mirroring(dropAfter: .seconds(1), variation: .staleCopy(dropAfter: dropAfter)))
    defer { Self.remove(fixture) }
    await fixture.run.runSteps()
    await fixture.run.cleanUp()
    let lines = fixture.lines.withLock { $0 }
    if dropAfter != nil {
      #expect(await fixture.run.passedCount == PersistentProfileRun.stepCount, "\(lines)")
      #expect(lines.first?.hasPrefix("PASS 1 snapshot before") == true)
      #expect(
        lines[1]
          == "  note: New Bookmarks held 1 mirrored muxFinder entry naming muxFinder.json, which "
          + "does not exist (an earlier run's); iTerm2 dropped it 2000 ms later, before the hashes "
          + "were recorded")
    } else {
      #expect(lines.first?.hasPrefix("FAIL 1 snapshot before (5000 ms): ") == true, "\(lines)")
      #expect(
        lines.first?.hasSuffix(
          "New Bookmarks holds 1 mirrored muxFinder entry naming muxFinder.json, which does not "
            + "exist (an earlier run's or the app's), and iTerm2 did not drop it within 5.0 "
            + "seconds, so the baseline is unexplained and the run does not start (rerun once "
            + "muxfinder-probe profiles hashes shows excludedMuxFinderEntries 0)") == true)
      #expect(await fixture.tmux.sessions.isEmpty)
      #expect(await fixture.iTerm2.createdTabs.isEmpty)
      #expect(!LaunchTestSupport.exists(fixture.folder.installer.fileURL))
      #expect(await fixture.run.passedCount == 1)
    }
    #expect(lines.last?.hasPrefix("PASS 14 cleanup") == true)
    #expect(try await Self.leftovers(fixture).isEmpty)
  } // End of func baselineCopyIsWaitedForOrRefused(dropAfter:)

  /// A change to one of the user's profiles in `New Bookmarks` still fails the comparison,
  /// with the copy left out: at step 8 while the profile is installed, at step 13 once iTerm2
  /// dropped the copy.
  @Test(arguments: [MirroringDefaults.UserChange.whileInstalled, .afterRemoval])
  func changedUserProfileStillFails(change: MirroringDefaults.UserChange) async throws {
    let fixture = try Self.fixture(mirroring: Mirroring(dropAfter: .seconds(12), change: change))
    defer { Self.remove(fixture) }
    await fixture.run.runSteps()
    await fixture.run.cleanUp()
    let lines = fixture.lines.withLock { $0 }
    let step = change == .whileInstalled ? 8 : 13
    let failure = try #require(
      lines.firstIndex { $0.hasPrefix("FAIL \(step) snapshot") }, "\(lines)")
    #expect(lines[failure].hasSuffix("iTerm2's other profiles changed: New Bookmarks"))
    #expect(lines[failure + 1] == (step == 8 ? Self.installedNote : Self.droppedNote))
    #expect(lines.last?.hasPrefix("PASS 14 cleanup") == true)
    #expect(await fixture.run.passedCount == step)
    #expect(try await Self.leftovers(fixture).isEmpty)
  } // End of func changedUserProfileStillFails(change:)

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
