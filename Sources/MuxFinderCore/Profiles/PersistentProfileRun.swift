import Foundation

/// tmux on the host under test as the persistent profile harness drives it (PLAN.md D26): the
/// default server, and only the run's own `muxfinder-test-*` session, by its exact name or its
/// recorded identity. The probe implements it locally (argv) and over ssh (`BatchMode`, a static
/// script, quoted arguments, no remote file); tests pass an in-memory fake.
public protocol ProfileRunTmux: Sendable {
  /// Where tmux runs, for the header: `at <path>` or `on <destination>`.
  var location: String { get }
  /// `tmux -V`, or `nil`.
  func version() async -> String?
  /// Creates the session `name`, detached, its panes running `sleep 600` (no login shell), and
  /// returns it as `new-session -P -F CreatedSession.format` printed it.
  func createSession(named name: String) async throws -> CreatedSession
  /// The session named exactly `name`, or `nil` (also when no server runs).
  func findSession(named name: String) async throws -> CreatedSession?
  /// Kills `record`'s session only while it is still exactly that session
  /// (`CreatedSession.killIfUnchangedArguments`, one tmux command).
  func killIfUnchanged(_ record: CreatedSession) async throws -> CreatedSession.KillOutcome
}

/// Why a harness step failed, in plain words.
public struct ProfileRunFailure: Error, Sendable, Hashable {
  /// The explanation.
  public let detail: String

  /// Creates a failure.
  public init(_ detail: String) {
    self.detail = detail
  }
}

/// `muxfinder-probe e2e-profile --local | --ssh <destination>` (PLAN.md D26): the real run of a
/// persistent profile, for Phase 11b. Every part is a seam, so the whole run is tested
/// hermetically with fakes; the probe wires the real iTerm2 client, installer, snapshotter,
/// launch store, tmux, discovery and clock.
///
/// Steps (each prints a PASS or FAIL line; the first failure stops the run, then cleanup runs):
/// 1. **snapshot before:** iTerm2's API must answer; the run refuses to start when
///    `DynamicProfiles/muxFinder.json` exists (it is the user's then) or a session named
///    `muxfinder-test-profile` exists (it is not the run's); then the hash snapshot of iTerm2's
///    other profiles (`ITerm2ProfileSnapshot`). A copy of a muxFinder profile in `New
///    Bookmarks` then (`ITerm2ProfileSnapshotter.MirrorRule` without written profiles) is
///    unexplained, since no `muxFinder.json` exists: the run snapshots every
///    `mirrorPollInterval` for at most `baselineMirrorDrop` until none is left (a note says how
///    long that took) and otherwise fails, so the baseline never holds one.
/// 2. **create session:** `muxfinder-test-profile` on the host's default server, panes running
///    `sleep 600`, so the profile's `new-session -A` attaches it and no login shell ever starts
///    in tmux; discovery must list it as created, which gives the host's node name.
/// 3. **install profile:** the test host (a fresh id, `muxFinder test <hex>`, the profile on,
///    the session above, this Mac or the destination) goes to a test host list in the launch
///    directory and test mode is turned on (the marker), so the helper iTerm2 starts reads that
///    list and never the user's `hosts.json` (`LaunchStore.profileTestHostsURL(forHostID:)`);
///    the profile file (`PersistentProfiles.document`, the command exactly `<helper> profile
///    <id>`) is installed with `createOnly`, so a `muxFinder.json` that appeared since step 1 is
///    never replaced.
/// 4. **profile listed:** `ListProfiles` for the GUID shows it with its name.
/// 5. **open tab:** `CreateTab(profile_name: …)` without a window id (a new window).
/// 6. **connection:** a tmux connection owned by that tab appears; the helper's argv digest is
///    exactly `<helper> profile <id>` and its child the expected tmux (or ssh) argv.
/// 7. **identity:** the connection, asked through the owned-connection binding (D15), shows the
///    created session on the created server and, by `#{host}`, the host discovery reported.
/// 8. **snapshot installed:** hashes the same as the first (`ITerm2ProfileSnapshot.hashesMatch`):
///    only iTerm2's copy of the run's own profile in `New Bookmarks` is left out of the hash
///    (its exact GUID, the owned file's path, every key the run wrote unchanged) and counted in
///    a note; any other entry, a look-alike or a changed copy included, is hashed.
/// 9. **detach:** once the tab is `minimumTabAge` old, `detach-client` through the binding; the
///    connection closes, the helper ends and the tab closes by itself; the session survives.
/// 10. **kill session:** only while it is still exactly the created one.
/// 11. **remove profile:** the profile file, only while it holds the bytes the run wrote, and the
///    test host list.
/// 12. **profile gone:** `ListProfiles` no longer shows the GUID.
/// 13. **snapshot after:** snapshots every `mirrorPollInterval` until `New Bookmarks` holds no
///    copy of the run's profile any more (iTerm2 drops it after the file goes), reports how long
///    after the removal that was, and then hashes the same as the first. The wait has one
///    absolute deadline, `mirrorDrop` after step 11 removed the file (so a slow step 12 leaves
///    less of it); each snapshot's `defaults export` and each pause are capped to what is left,
///    and a snapshot that ends after the deadline does not count, so the step fails then.
///
/// **Cleanup** (step 14, on every way out): once the tab is `minimumTabAge` old, every tmux
/// connection iTerm2 lists as owned by it (one that appeared after step 6's wait too) is
/// detached through the binding until a listing shows none; the run's own tab is closed
/// (forced, by the session id `CreateTab` returned) only when it did not close by itself and a
/// listing taken just before shows it owns no connection. A connection still owned after that
/// (a failed or unanswered detach), or no listing at all, leaves the tab open and the session
/// alive, and cleanup fails with the commands that finish it by hand. Otherwise the session is
/// killed only while unchanged. Then the profile file is removed only while it holds the run's
/// bytes, and the test host list and the test-mode marker the run created are removed. It
/// never asks, detaches or closes anything the run did not create, never touches another tmux
/// session, and never writes iTerm2's preferences.
public actor PersistentProfileRun {
  /// What the run is about.
  public enum Kind: Sendable, Hashable {
    /// This Mac's default tmux server.
    case local
    /// The default tmux server of the host at this SSH destination.
    case remote(destination: String)
  }

  /// The run's parts (every one a seam).
  public struct Parts: Sendable {
    /// iTerm2.
    public var iTerm2: any ITerm2Integration
    /// The installer over iTerm2's `DynamicProfiles` folder.
    public var installer: PersistentProfileInstaller
    /// Takes the hash snapshot with the given options (what the run wrote, the export's
    /// deadline).
    public var snapshot:
      @Sendable (ITerm2ProfileSnapshotter.Options) async throws -> ITerm2ProfileSnapshot
    /// The launch directory (test-mode marker, test host list, argv digests).
    public var store: LaunchStore
    /// tmux on the host under test.
    public var tmux: any ProfileRunTmux
    /// Discovery of the host under test.
    public var discovery: any HostDiscovering
    /// Time.
    public var clock: any AttachClock
    /// Where the PASS, FAIL and note lines go.
    public var output: @Sendable (String) -> Void

    /// Creates the parts.
    public init(
      iTerm2: any ITerm2Integration,
      installer: PersistentProfileInstaller,
      snapshot:
        @escaping @Sendable (ITerm2ProfileSnapshotter.Options) async throws ->
        ITerm2ProfileSnapshot,
      store: LaunchStore,
      tmux: any ProfileRunTmux,
      discovery: any HostDiscovering,
      clock: any AttachClock,
      output: @escaping @Sendable (String) -> Void
    ) {
      self.iTerm2 = iTerm2
      self.installer = installer
      self.snapshot = snapshot
      self.store = store
      self.tmux = tmux
      self.discovery = discovery
      self.clock = clock
      self.output = output
    } // End of init(iTerm2:installer:snapshot:store:tmux:discovery:clock:output:)
  } // End of struct Parts

  /// The run's limits.
  public struct Limits: Sendable, Hashable {
    /// How long iTerm2 may take to list (or drop) the profile after the file changed.
    public var profileListing: Duration = .seconds(15)
    /// How long the connection may take to appear after `CreateTab`.
    public var connection: Duration
    /// How long the connection and the tab may take to close after `detach-client`.
    public var closing: Duration = .seconds(10)
    /// How long the helper's argv digest may take to appear.
    public var digest: Duration = .seconds(5)
    /// The pause between two polls.
    public var pollInterval: Duration = .milliseconds(200)
    /// How long iTerm2 may keep its copy of muxFinder's profile in `New Bookmarks` after the
    /// file was removed: step 13's absolute deadline, counted from step 11's removal.
    public var mirrorDrop: Duration = .seconds(30)
    /// How long step 1 waits for a copy of a muxFinder profile found in `New Bookmarks` without
    /// a `muxFinder.json` to go before it fails (iTerm2 dropped its copies within 0.3 s in
    /// Phase 11b's runs).
    public var baselineMirrorDrop: Duration = .seconds(5)
    /// The pause between two snapshots while waiting for such a copy to go (each runs `defaults
    /// export`).
    public var mirrorPollInterval: Duration = .milliseconds(500)
    /// How old the tab must be before the run ends it in any way (iTerm2's short-lived-session
    /// warning, PLAN.md D15).
    public var minimumTabAge: Duration = AttachCoordinator.Configuration().minimumLaunchTabAge

    /// The limits for `kind`: the connection budget is D15's 15 s locally, D17's 20 s remotely.
    public init(kind: Kind) {
      connection = kind == .local ? .seconds(15) : .seconds(20)
    }
  } // End of struct Limits

  /// The session the profile attaches.
  public static let sessionName = "muxfinder-test-profile"
  /// The number of steps, cleanup included.
  public static let stepCount = 14

  /// What the run is about.
  public nonisolated let kind: Kind
  /// The helper iTerm2 runs.
  public nonisolated let helper: LaunchHelperPath
  /// The tmux the helper's local check finds (the D5 order on this Mac); `nil` remotely.
  public nonisolated let localTmuxPath: String?
  /// The parts.
  let parts: Parts
  /// The limits.
  let limits: Limits
  /// The test host: a fresh id, so no profile of the user's and no host of theirs is named.
  public nonisolated let host: HostConfig
  /// The profile's GUID.
  public nonisolated let guid: String
  /// The profile's name.
  public nonisolated let profileName: String

  /// Steps that passed.
  public private(set) var passedCount = 0
  /// The first snapshot.
  private var firstSnapshot: ITerm2ProfileSnapshot?
  /// The created session, once known.
  private var created: CreatedSession?
  /// The host's node name, from discovery.
  private var nodeName: String?
  /// The installed file's bytes, while the run's file may be installed.
  private var installedBytes: Data?
  /// The profiles the run wrote into the file (step 3), which steps 8 and 13 leave out of the
  /// hash only as iTerm2's unchanged copies.
  private var written: [ITerm2ProfileSnapshotter.WrittenProfile]?
  /// When step 11 removed the profile file.
  private var removedAt: ContinuousClock.Instant?
  /// Whether the run wrote the test host list.
  private var testHostsWritten = false
  /// Whether the run created the test-mode marker.
  private var markerCreated = false
  /// The tab `CreateTab` opened, and when.
  private var tab: (sessionID: String, openedAt: ContinuousClock.Instant)?
  /// The tab's tmux connection, once found.
  private var connectionID: String?
  /// Notes printed after the current step.
  private var notes: [String] = []

  /// Creates the run for `kind` with the helper at `helper` and the local tmux path the
  /// helper's check would find (`nil` remotely).
  public init(
    kind: Kind,
    helper: LaunchHelperPath,
    localTmuxPath: String?,
    parts: Parts,
    limits: Limits? = nil
  ) {
    self.kind = kind
    self.helper = helper
    self.localTmuxPath = localTmuxPath
    self.parts = parts
    self.limits = limits ?? Limits(kind: kind)
    let suffix = String(format: "%08x", UInt32.random(in: .min ... .max))
    switch kind {
    case .local:
      host = HostConfig(
        displayName: "muxFinder test \(suffix)", mode: .local, persistentProfileEnabled: true,
        defaultSessionName: Self.sessionName)
    case .remote(let destination):
      host = HostConfig(
        displayName: "muxFinder test \(suffix)", mode: .ssh, sshDestination: destination,
        persistentProfileEnabled: true, defaultSessionName: Self.sessionName)
    }
    guid = PersistentProfiles.guid(forHostID: host.id)
    profileName = PersistentProfiles.name(for: host)
  } // End of init(kind:helper:localTmuxPath:parts:limits:)

  /// The command's name for the output.
  public nonisolated var name: String {
    switch kind {
    case .local: return "e2e-profile --local"
    case .remote: return "e2e-profile --ssh"
    }
  }

  // MARK: - Steps

  /// Steps 1–13, stopping at the first failure. Cleanup is `cleanUp()`.
  public func runSteps() async {
    guard await step(1, "snapshot before", { try await self.snapshotBefore() }),
      await step(2, "create session", { try await self.createSession() }),
      await step(3, "install profile", { try await self.installProfile() }),
      await step(4, "profile listed", { try await self.waitForProfile(listed: true) }),
      await step(5, "open tab", { try await self.openTab() }),
      await step(6, "connection", { try await self.waitForConnection() }),
      await step(7, "identity", { try await self.checkIdentity() }),
      await step(8, "snapshot installed", { try await self.compareInstalledSnapshot() }),
      await step(9, "detach", { try await self.detach() }),
      await step(10, "kill session", { try await self.killSession() }),
      await step(11, "remove profile", { try await self.removeProfile() }),
      await step(12, "profile gone", { try await self.waitForProfile(listed: false) }),
      await step(13, "snapshot after", { try await self.compareSnapshotAfterRemoval() })
    else { return }
  } // End of func runSteps()

  /// Runs one step and prints its PASS or FAIL line and notes. Returns whether it passed.
  private func step(
    _ number: Int,
    _ title: String,
    _ body: () async throws -> String
  ) async -> Bool {
    let start = parts.clock.now()
    notes.removeAll()
    let passed: Bool
    let detail: String
    do {
      detail = try await body()
      passed = true
    } catch let failure as ProfileRunFailure {
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
    let elapsed = Int((parts.clock.now() - start) / .milliseconds(1))
    parts.output("\(passed ? "PASS" : "FAIL") \(number) \(title) (\(elapsed) ms): \(detail)")
    for note in notes { parts.output("  note: \(note)") }
    if passed { passedCount += 1 }
    return passed
  } // End of func step(_:_:_:)

  /// Step 1.
  private func snapshotBefore() async throws -> String {
    let status = await parts.iTerm2.status()
    guard status.isConnected else {
      throw ProfileRunFailure(
        "iTerm2's API is not reachable (\(status.error?.kind ?? "unknown"))")
    }
    if try parts.installer.installedContents() != nil {
      throw ProfileRunFailure(
        "\(PersistentProfiles.fileName) exists in DynamicProfiles; it is not this run's, so the "
          + "run does not start (move it away to run)")
    }
    if try await parts.tmux.findSession(named: Self.sessionName) != nil {
      throw ProfileRunFailure(
        "a session named \(Self.sessionName) exists already; it is not this run's, so the run "
          + "does not start (end it yourself if it is a leftover)")
    }
    var snapshot = try await parts.snapshot(ITerm2ProfileSnapshotter.Options())
    if snapshot.excludedMuxFinderEntries > 0 {
      // No muxFinder.json exists, so a copy of a muxFinder profile is unexplained: the baseline
      // must not hold one (it would be left out at steps 8 and 13 for no known reason).
      let found = snapshot.excludedMuxFinderEntries
      let start = parts.clock.now()
      let wait = try await waitForNoMirror(
        written: nil, until: start + limits.baselineMirrorDrop, after: snapshot)
      guard let settled = wait.settled, let settledAt = wait.settledAt else {
        throw ProfileRunFailure(
          "New Bookmarks holds \(Self.mirrors(wait.last?.excludedMuxFinderEntries ?? found)) "
            + "naming \(PersistentProfiles.fileName), which does not exist (an earlier run's or "
            + "the app's), and iTerm2 did not drop it within \(limits.baselineMirrorDrop), so the "
            + "baseline is unexplained and the run does not start (rerun once muxfinder-probe "
            + "profiles hashes shows excludedMuxFinderEntries 0)")
      }
      snapshot = settled
      notes.append(
        "New Bookmarks held \(Self.mirrors(found)) naming \(PersistentProfiles.fileName), which "
          + "does not exist (an earlier run's); iTerm2 dropped it "
          + "\(Int((settledAt - start) / .milliseconds(1))) ms later, before the hashes were "
          + "recorded")
    } // End of the wait for an unexplained copy to go
    firstSnapshot = snapshot
    return
      "\(snapshot.entryCount) other DynamicProfiles entr\(snapshot.entryCount == 1 ? "y" : "ies"), "
      + "New Bookmarks with \(snapshot.newBookmarks?.count ?? 0) profile(s) hashed; hashes recorded"
  } // End of func snapshotBefore()

  /// Step 2.
  private func createSession() async throws -> String {
    let record = try await parts.tmux.createSession(named: Self.sessionName)
    created = record
    guard record.name == Self.sessionName else {
      throw ProfileRunFailure("tmux reported another name for the created session")
    }
    let result = try await parts.discovery.discover(host)
    guard case .ok(let sessions) = result.status,
      sessions.contains(where: { record.matches($0) }),
      let node = result.report?.nodeName
    else {
      throw ProfileRunFailure("discovery did not list the created session (\(result.status.kind))")
    }
    nodeName = node
    return "\(record.sessionID) created (panes run sleep 600) and discovered"
  } // End of func createSession()

  /// Step 3.
  private func installProfile() async throws -> String {
    try parts.store.createTestModeMarker()
    markerCreated = true
    _ = try? parts.store.takeArgvDigests()
    try parts.store.writeProfileTestHosts(try HostList([host]), forHostID: host.id)
    testHostsWritten = true
    let document = try PersistentProfiles.document(for: try HostList([host]), helper: helper)
    guard
      let profiles = ITerm2ProfileSnapshotter.WrittenProfile.profiles(inDocument: document.data),
      profiles.map(\.guid) == [guid]
    else { throw ProfileRunFailure("the generated profile file does not hold the run's profile") }
    try parts.installer.install(document, replacing: .createOnly)
    installedBytes = document.data
    written = profiles
    notes.append("profile command: <helper> profile <test host id>; helper test mode on")
    return "\(PersistentProfiles.fileName) written with 1 profile (\(document.data.count) bytes)"
  } // End of func installProfile()

  /// Steps 4 and 12: polls `ListProfiles` for the GUID until it is listed (with its name) or
  /// gone.
  private func waitForProfile(listed: Bool) async throws -> String {
    let start = parts.clock.now()
    let found = try await poll(within: limits.profileListing) { () -> Bool? in
      let profiles = try await self.parts.iTerm2.listProfiles(
        properties: [ITerm2API.ProfileProperty.Key.guid, ITerm2API.ProfileProperty.Key.name],
        guids: [self.guid])
      let mine = profiles.filter { $0.guid == self.guid }
      if listed {
        return mine.contains(where: { $0.name == self.profileName }) ? true : nil
      }
      return mine.isEmpty ? true : nil
    }
    guard found == true else {
      throw ProfileRunFailure(
        listed
          ? "iTerm2 did not list the profile within \(limits.profileListing)"
          : "iTerm2 still lists the profile after \(limits.profileListing)")
    }
    let elapsed = Int((parts.clock.now() - start) / .milliseconds(1))
    return listed
      ? "ListProfiles shows the GUID with its name after \(elapsed) ms"
      : "ListProfiles no longer shows the GUID after \(elapsed) ms"
  } // End of func waitForProfile(listed:)

  /// Step 5.
  private func openTab() async throws -> String {
    switch await LaunchTab.open(
      ITerm2API.CreateTabRequest(profileName: profileName), on: parts.iTerm2)
    {
    case .failure(let error):
      throw error
    case .success(let sessionID):
      tab = (sessionID, parts.clock.now())
      return "CreateTab(profile_name) opened a new window, tab session \(sessionID)"
    }
  } // End of func openTab()

  /// Step 6.
  private func waitForConnection() async throws -> String {
    guard let tab else { throw ProfileRunFailure("no tab") }
    let found = try await poll(within: limits.connection) { () -> String? in
      try await self.parts.iTerm2.listTmuxConnections().first {
        $0.owningSessionID == tab.sessionID
      }?.connectionID
    }
    guard let found else {
      throw ProfileRunFailure(
        "no tmux connection owned by the tab within \(limits.connection) (the tab may show why)")
    }
    connectionID = found
    let elapsed = Int((parts.clock.now() - tab.openedAt) / .milliseconds(1))
    let digest = try await checkDigest()
    return "connection \(found) owned by the tab \(elapsed) ms after CreateTab; \(digest)"
  } // End of func waitForConnection()

  /// The helper's argv digest: exactly `<helper> profile <id>`, and its child the expected
  /// tmux (locally `<tmux> -u -CC new-session -A -s muxfinder-test-profile`) or ssh argv
  /// (D17's options, the destination and the static remote script with an empty override and
  /// the name), written out here, not taken from the code under test (but the static script).
  private func checkDigest() async throws -> String {
    let token = LaunchToken(uuid: host.id)
    // The helper writes its digest at start and again with its child just before starting it;
    // one taken in between lacks the child, so polling goes on for the second write.
    var latest: LaunchArgvDigest?
    let complete = try await poll(within: limits.digest) { () -> LaunchArgvDigest? in
      let mine = try self.parts.store.takeArgvDigests().filter { $0.launchID == token }
      if let last = mine.last { latest = last }
      return mine.last { $0.attachChild != nil }
    }
    guard let digest = complete ?? latest else {
      throw ProfileRunFailure("the helper wrote no argv digest")
    }
    let expected = [helper.path, "profile", token.rawValue].map {
      LaunchArgvDigest.Argument(bytes: Array($0.utf8))
    }
    guard digest.argumentCount == 3, digest.arguments == expected else {
      throw ProfileRunFailure(
        "iTerm2 gave the helper \(digest.argumentCount) arguments, not <helper> profile <id>")
    }
    let child: [String]
    switch kind {
    case .local:
      guard let localTmuxPath else { throw ProfileRunFailure("no local tmux path") }
      child = [localTmuxPath, "-u", "-CC", "new-session", "-A", "-s", Self.sessionName]
    case .remote(let destination):
      child = [
        "/usr/bin/ssh", "-t", "-o", "ConnectTimeout=10", "--", destination,
        ShellQuoting.remoteCommand(
          script: ProfileLaunch.remoteScript, args: ["", Self.sessionName]),
      ]
    }
    let wanted = LaunchArgvDigest.AttachChild(
      executable: child[0], arguments: Array(child.dropFirst()), detachesOtherClients: false)
    guard digest.attachChild == wanted else {
      throw ProfileRunFailure(
        "the helper's child (\(digest.attachChild?.argumentCount ?? 0) arguments"
          + "\(digest.attachChild?.startsLoginShell == true ? ", the login shell" : "")) is not "
          + "the expected \(wanted.argumentCount)")
    }
    return "iTerm2 split the Command into exactly <helper> profile <id>; the helper's child had "
      + "exactly the expected \(wanted.argumentCount) arguments"
  } // End of func checkDigest()

  /// Step 7.
  private func checkIdentity() async throws -> String {
    guard let tab, let connectionID, let created, let nodeName else {
      throw ProfileRunFailure("no connection")
    }
    let answer = try await parts.iTerm2.sendTmuxCommand(
      ConnectionIdentity.command, connectionID: connectionID, ownedBy: tab.sessionID)
    guard let reported = ConnectionIdentity.parse(answer) else {
      throw ProfileRunFailure("the connection's identity answer was not readable")
    }
    guard reported.server == created.server, reported.sessionID == created.sessionID else {
      throw ProfileRunFailure("the connection shows another server or session than the created one")
    }
    guard reported.host == nodeName else {
      throw ProfileRunFailure("the connection's #{host} is not the node name discovery reported")
    }
    return "the connection shows \(created.sessionID) (\(Self.sessionName)) on the created "
      + "server, host matching discovery: a confirmed control-mode attachment"
  } // End of func checkIdentity()

  /// Step 8: the snapshot with the profile installed hashes the same as the first. Only
  /// iTerm2's unchanged copy of the run's own profile in `New Bookmarks` is left out of the
  /// hash; a note counts it.
  private func compareInstalledSnapshot() async throws -> String {
    guard let firstSnapshot, let written else {
      throw ProfileRunFailure("no first snapshot or no installed profile")
    }
    let now = try await parts.snapshot(ITerm2ProfileSnapshotter.Options(written: written))
    notes.append(
      "New Bookmarks: \(Self.mirrors(now.excludedMuxFinderEntries)) left out of the hash "
        + "(iTerm2 copies loaded dynamic profiles there)")
    try requireSameHashes(now, as: firstSnapshot)
    return "identical to the first snapshot (\(now.entryCount) entries, New Bookmarks "
      + "\(now.newBookmarks?.count ?? 0) hashed)"
  } // End of func compareInstalledSnapshot()

  /// Step 13: snapshots until `New Bookmarks` holds no copy of the run's profile, by one
  /// absolute deadline, `mirrorDrop` after step 11's removal (`waitForNoMirror`; the file is
  /// gone by now, so a copy left is iTerm2's alone and there is nothing to clean up), then
  /// requires the same hashes as the first snapshot. Reports how long after the removal the
  /// copy was gone.
  private func compareSnapshotAfterRemoval() async throws -> String {
    guard let firstSnapshot, let removedAt, let written else {
      throw ProfileRunFailure("no first snapshot, no installed profile or no removal")
    }
    let wait = try await waitForNoMirror(written: written, until: removedAt + limits.mirrorDrop)
    guard let settled = wait.settled, let settledAt = wait.settledAt else {
      let late = wait.endedLate ? "; a snapshot that ended after that was not counted" : ""
      guard let last = wait.last else {
        let why =
          wait.endedLate
          ? "the last one ended after that and was not counted" : "no time was left after step 12"
        throw ProfileRunFailure(
          "no snapshot of New Bookmarks ended within \(limits.mirrorDrop) of "
            + "\(PersistentProfiles.fileName)'s removal (\(why); the file is gone, nothing else to "
            + "clean up)")
      }
      let changed = last.differences(from: firstSnapshot)
      let others =
        changed.isEmpty
        ? "the other profiles hash as before"
        : "the other profiles changed too: \(changed.joined(separator: ", "))"
      throw ProfileRunFailure(
        "iTerm2 still holds \(Self.mirrors(last.excludedMuxFinderEntries)) in New "
          + "Bookmarks \(limits.mirrorDrop) after \(PersistentProfiles.fileName) was removed "
          + "(\(others)\(late); the file is gone, nothing else to clean up)")
    } // End of the failure without a snapshot free of the run's copy
    let elapsed = Int((settledAt - removedAt) / .milliseconds(1))
    notes.append(
      wait.sawMirror
        ? "iTerm2 dropped its copy of the profile from New Bookmarks \(elapsed) ms after the file "
          + "was removed"
        : "New Bookmarks held no copy of a muxFinder profile \(elapsed) ms after the file was "
          + "removed")
    try requireSameHashes(settled, as: firstSnapshot)
    return "identical to the first snapshot (\(settled.entryCount) entries, New Bookmarks "
      + "\(settled.newBookmarks?.count ?? 0) hashed) once New Bookmarks held no muxFinder copy, "
      + "\(elapsed) ms after the removal"
  } // End of func compareSnapshotAfterRemoval()

  /// What `waitForNoMirror` saw.
  private struct MirrorWait {
    /// The first snapshot without a copy that ended by the deadline, if any.
    var settled: ITerm2ProfileSnapshot?
    /// When that snapshot ended.
    var settledAt: ContinuousClock.Instant?
    /// The last snapshot that ended by the deadline.
    var last: ITerm2ProfileSnapshot?
    /// Whether a snapshot held a copy.
    var sawMirror = false
    /// Whether the last snapshot ended (or failed) after the deadline and was not counted.
    var endedLate = false
  } // End of struct MirrorWait

  /// Snapshots (`written` as the options' written profiles) until one that ends by `deadline`
  /// holds no copy of a muxFinder profile (`excludedMuxFinderEntries` 0), pausing
  /// `mirrorPollInterval` between two. Every `defaults export` gets at most what is left before
  /// `deadline`, every pause too; a snapshot that ends after `deadline`, or fails once it has
  /// passed, is not counted and ends the wait. `first`, a snapshot already taken that holds a
  /// copy, makes it pause before its first snapshot. Cancellation ends it with
  /// `CancellationError`.
  private func waitForNoMirror(
    written: [ITerm2ProfileSnapshotter.WrittenProfile]?,
    until deadline: ContinuousClock.Instant,
    after first: ITerm2ProfileSnapshot? = nil
  ) async throws -> MirrorWait {
    var wait = MirrorWait(last: first, sawMirror: first != nil)
    if first != nil, try await !pause(before: deadline) { return wait }
    while true {
      try Task.checkCancellation()
      let remaining = deadline - parts.clock.now()
      guard remaining > .zero else { return wait }
      let options = ITerm2ProfileSnapshotter.Options(
        written: written, exportTimeout: min(ITerm2ProfileSnapshotter.exportTimeout, remaining))
      let snapshot: ITerm2ProfileSnapshot
      do {
        snapshot = try await parts.snapshot(options)
      } catch let error where !(error is CancellationError) && parts.clock.now() >= deadline {
        // The export was cut at the deadline (or failed past it): out of time, not a failure
        // of its own.
        try Task.checkCancellation()
        wait.endedLate = true
        return wait
      }
      let endedAt = parts.clock.now()
      guard endedAt <= deadline else {
        wait.endedLate = true
        return wait
      }
      wait.last = snapshot
      guard snapshot.excludedMuxFinderEntries > 0 else {
        (wait.settled, wait.settledAt) = (snapshot, endedAt)
        return wait
      }
      wait.sawMirror = true
      guard try await pause(before: deadline) else { return wait }
    } // End of loop over the snapshots
  } // End of func waitForNoMirror(written:until:after:)

  /// Sleeps `mirrorPollInterval`, or what is left before `deadline` when that is less; returns
  /// `false` without sleeping when nothing is left.
  private func pause(before deadline: ContinuousClock.Instant) async throws -> Bool {
    let left = deadline - parts.clock.now()
    guard left > .zero else { return false }
    try await parts.clock.sleep(for: min(limits.mirrorPollInterval, left))
    return true
  }

  /// Throws, naming what changed, unless `snapshot` hashes the same as `first`; when the
  /// number of hashed `New Bookmarks` entries differs, a note gives both (an entry that only
  /// looks like a copy of the run's profile is hashed, so it shows as one more).
  private func requireSameHashes(
    _ snapshot: ITerm2ProfileSnapshot,
    as first: ITerm2ProfileSnapshot
  ) throws {
    guard snapshot.hashesMatch(first) else {
      if let now = snapshot.newBookmarks?.count, let before = first.newBookmarks?.count,
        now != before
      {
        notes.append("New Bookmarks: \(now) profiles hashed now, \(before) in the first snapshot")
      }
      throw ProfileRunFailure(
        "iTerm2's other profiles changed: "
          + snapshot.differences(from: first).joined(separator: ", "))
    }
  } // End of func requireSameHashes(_:as:)

  /// `count` mirrored muxFinder entries, in words.
  private static func mirrors(_ count: Int) -> String {
    "\(count) mirrored muxFinder entr\(count == 1 ? "y" : "ies")"
  }

  /// Step 9.
  private func detach() async throws -> String {
    guard let tab, let connectionID else { throw ProfileRunFailure("no connection") }
    try await waitUntilTabIsOldEnough()
    _ = try await parts.iTerm2.sendTmuxCommand(
      ConnectionIdentity.detachCommand, connectionID: connectionID, ownedBy: tab.sessionID)
    let closed = try await poll(within: limits.closing) { () -> Bool? in
      let open = try await self.parts.iTerm2.listTmuxConnections().contains {
        $0.owningSessionID == tab.sessionID
      }
      return open ? nil : true
    }
    guard closed == true else { throw ProfileRunFailure("the connection stayed open") }
    self.connectionID = nil
    let tabClosed = try await poll(within: limits.closing) { () -> Bool? in
      try await self.parts.iTerm2.listSessions().allSessionIDs.contains(tab.sessionID) ? nil : true
    }
    guard tabClosed == true else {
      throw ProfileRunFailure("the tab stayed open after tmux ended (the helper did not end)")
    }
    self.tab = nil
    guard let created, try await parts.tmux.findSession(named: Self.sessionName) == created else {
      throw ProfileRunFailure("the session did not survive the detach as it was")
    }
    return "detach-client through the tab's connection: the connection closed, the helper ended "
      + "and the tab closed by itself; the session survived"
  } // End of func detach()

  /// Step 10.
  private func killSession() async throws -> String {
    guard let created else { throw ProfileRunFailure("no session") }
    let outcome = try await parts.tmux.killIfUnchanged(created)
    guard outcome == .killed else { throw ProfileRunFailure("kill: \(outcome.rawValue)") }
    self.created = nil
    return "\(created.sessionID) killed (it was still exactly the created session)"
  }

  /// Step 11.
  private func removeProfile() async throws -> String {
    guard let installedBytes else { throw ProfileRunFailure("no profile file") }
    let outcome = try parts.installer.remove(expecting: installedBytes)
    guard outcome == .removed else { throw ProfileRunFailure("the profile file was gone") }
    self.installedBytes = nil
    removedAt = parts.clock.now()
    try parts.store.removeProfileTestHosts(forHostID: host.id)
    testHostsWritten = false
    return "\(PersistentProfiles.fileName) removed (it still held the run's bytes); test host list "
      + "removed"
  } // End of func removeProfile()

  // MARK: - Cleanup

  /// Step 14 (see the type's documentation). Prints a PASS line when nothing of the run is left,
  /// else a FAIL line naming what is, followed by the commands that finish the cleanup by hand
  /// when the run's tab may still be attached.
  public func cleanUp() async {
    let start = parts.clock.now()
    var actions: [String] = []
    var problems: [String] = []
    var byHand: [String] = []
    if let tab {
      try? await waitUntilTabIsOldEnough(ignoringCancellation: true)
      let left = await endTab(tab.sessionID, actions: &actions, problems: &problems)
      if left != [] {
        // Unresolved: neither the tab nor the session is ended, so nothing closes a tab that
        // may hold a tmux gateway or ends the session under it.
        let held =
          left.map { "it owns tmux connection(s) \($0.joined(separator: ", "))" }
          ?? "iTerm2's tmux connections could not be listed"
        problems.append(
          "the run's tab \(tab.sessionID) may still be attached (\(held)), so the tab was left "
            + "open and \(Self.sessionName) was not killed")
        byHand = manualCleanup(tab: tab.sessionID, connections: left)
      }
      self.tab = nil
      self.connectionID = nil
    } // End of the run's tab
    if let created, byHand.isEmpty {
      switch try? await parts.tmux.killIfUnchanged(created) {
      case .killed?: actions.append("killed \(Self.sessionName)")
      case .notThisSession?: actions.append("\(Self.sessionName) was already gone")
      default: problems.append("\(Self.sessionName) could not be killed")
      }
      self.created = nil
    }
    if let installedBytes {
      do {
        try parts.installer.remove(expecting: installedBytes)
        actions.append("removed \(PersistentProfiles.fileName)")
        self.installedBytes = nil
      } catch {
        problems.append("\(PersistentProfiles.fileName) left as it is: \(error)")
      }
    }
    if testHostsWritten {
      if (try? parts.store.removeProfileTestHosts(forHostID: host.id)) != nil {
        testHostsWritten = false
      } else {
        problems.append("the test host list could not be removed")
      }
    }
    if markerCreated {
      _ = try? parts.store.takeArgvDigests()
      if (try? parts.store.removeTestModeMarker()) != nil {
        markerCreated = false
      } else {
        problems.append("the test-mode marker could not be removed")
      }
    }
    let elapsed = Int((parts.clock.now() - start) / .milliseconds(1))
    let detail =
      problems.isEmpty
      ? (actions.isEmpty ? "nothing left to clean up" : actions.joined(separator: "; "))
      : problems.joined(separator: "; ")
    parts.output("\(problems.isEmpty ? "PASS" : "FAIL") 14 cleanup (\(elapsed) ms): \(detail)")
    for line in byHand { parts.output("  \(line)") }
    if problems.isEmpty { passedCount += 1 }
  } // End of func cleanUp()

  /// Ends the run's tab `tabID` once it is old enough: detaches every tmux connection it owns
  /// (`detachConnections(ownedBy:actions:)`), waits for the tab to close by itself, and closes
  /// it (forced) only when a listing taken just before shows it owns no connection, since one
  /// may have appeared while waiting. Returns the connections the tab still owns, empty when a
  /// listing showed none, or `nil` when iTerm2's connections could not be listed; unless it is
  /// empty, the tab is left open.
  private func endTab(
    _ tabID: String,
    actions: inout [String],
    problems: inout [String]
  ) async -> [String]? {
    let owned = await detachConnections(ownedBy: tabID, actions: &actions)
    guard owned == [] else { return owned }
    let gone = try? await poll(within: limits.closing) { () -> Bool? in
      try await self.parts.iTerm2.listSessions().allSessionIDs.contains(tabID) ? nil : true
    }
    if gone == true { return [] }
    let ownedNow = await connections(ownedBy: tabID)
    guard ownedNow == [] else { return ownedNow }
    do {
      _ = try await parts.iTerm2.close(
        ITerm2API.CloseRequest(target: .sessions([tabID]), force: true))
      actions.append("closed the run's own tab (it held no tmux connection)")
    } catch {
      problems.append("the run's tab \(tabID) could not be closed (\(error))")
    }
    return []
  } // End of func endTab(_:actions:problems:)

  /// Detaches every tmux connection iTerm2 lists as owned by the run's tab `tabID` (one that
  /// appeared after step 6's wait too) with `detach-client` through the binding (D15), once
  /// per connection id, and lists again until none is owned, within `limits.closing`. A detach
  /// that fails or goes unanswered proves nothing: only a listing without the connection does.
  /// Returns what the last listing showed the tab owns (empty when none), or `nil` when the
  /// last listing failed.
  private func detachConnections(
    ownedBy tabID: String,
    actions: inout [String]
  ) async -> [String]? {
    let deadline = parts.clock.now() + limits.closing
    var sent: Set<String> = []
    while true {
      let owned = await connections(ownedBy: tabID)
      if owned == [] { return [] }
      for connection in owned ?? [] where connection != "?" && sent.insert(connection).inserted {
        do {
          _ = try await parts.iTerm2.sendTmuxCommand(
            ConnectionIdentity.detachCommand, connectionID: connection, ownedBy: tabID)
          actions.append("sent detach-client to the tab's connection \(connection)")
        } catch {
          actions.append("detach-client to the tab's connection \(connection) failed")
        }
      } // End of loop over the tab's connections not asked yet
      guard parts.clock.now() < deadline,
        (try? await parts.clock.sleep(for: limits.pollInterval)) != nil
      else { return owned }
    } // End of loop until the tab owns no connection
  } // End of func detachConnections(ownedBy:actions:)

  /// The ids of the tmux connections iTerm2 lists as owned by `tabID` (`?` for one without an
  /// id), or `nil` when the listing failed.
  private func connections(ownedBy tabID: String) async -> [String]? {
    guard let listed = try? await parts.iTerm2.listTmuxConnections() else { return nil }
    return listed.filter { $0.owningSessionID == tabID }.map { $0.connectionID ?? "?" }
  }

  /// How to finish by hand a cleanup that left the run's tab `tabID` possibly attached: the
  /// probe's bound detach of each connection it still owns (found with `iterm2
  /// list-connections` when they are not known), then the kill of the session by its exact
  /// name. Never closing the tab.
  private func manualCleanup(tab tabID: String, connections: [String]?) -> [String] {
    let known = (connections ?? []).filter { $0 != "?" }
    var lines = ["clean up by hand (detach, never close the tab), then end the session:"]
    if known.count != connections?.count {
      lines.append(
        "swift run muxfinder-probe iterm2 list-connections  (the connections owned by \(tabID))")
      lines.append("swift run muxfinder-probe detach --connection <id> --gateway \(tabID)")
    }
    for connection in known {
      lines.append("swift run muxfinder-probe detach --connection \(connection) --gateway \(tabID)")
    }
    lines.append("tmux kill-session -t '=\(Self.sessionName)'  (tmux \(parts.tmux.location))")
    return lines
  } // End of func manualCleanup(tab:connections:)

  // MARK: - Waiting

  /// Waits until the run's tab is `minimumTabAge` old. With `ignoringCancellation`, a cancelled
  /// caller still waits (cleanup must never end a young tab).
  private func waitUntilTabIsOldEnough(ignoringCancellation: Bool = false) async throws {
    guard let tab else { return }
    while true {
      let age = parts.clock.now() - tab.openedAt
      guard age < limits.minimumTabAge else { return }
      let remaining = limits.minimumTabAge - age
      if ignoringCancellation {
        let clock = parts.clock
        await Task.detached { try? await clock.sleep(for: remaining) }.value
      } else {
        try await parts.clock.sleep(for: remaining)
      }
    } // End of loop waiting for the tab's age
  } // End of func waitUntilTabIsOldEnough(ignoringCancellation:)

  /// Polls `condition` every `limits.pollInterval` until it returns a value or `limit` passes.
  /// Cancellation ends it with `CancellationError` (the clock's sleep).
  private func poll<Value: Sendable>(
    within limit: Duration,
    _ condition: () async throws -> Value?
  ) async throws -> Value? {
    let deadline = parts.clock.now() + limit
    while true {
      if let value = try await condition() { return value }
      guard parts.clock.now() < deadline else { return nil }
      try await parts.clock.sleep(for: limits.pollInterval)
    }
  } // End of func poll(within:_:)
}
