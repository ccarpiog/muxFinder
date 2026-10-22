import Foundation
import MuxFinderCore

/// One fixed popover state for previews, the `--preview-fixtures` window and tests.
public struct PreviewFixture: Sendable, Hashable, Identifiable {
  /// A short, stable name.
  public var id: String
  /// The caption shown above the state in the preview window.
  public var title: String
  /// The engine state shown (`nil`: still loading).
  public var state: RefreshState?
  /// How the host list loaded.
  public var hostList: HostListStatus?
  /// The search text.
  public var searchText: String
  /// The keyboard selection.
  public var selection: SessionKey?
  /// Per-session progress and failures.
  public var activities: [SessionKey: SessionActivity]
  /// The time relative times are measured against.
  public var now: Date

  /// Creates a fixture.
  public init(
    id: String,
    title: String,
    state: RefreshState?,
    hostList: HostListStatus? = .saved,
    searchText: String = "",
    selection: SessionKey? = nil,
    activities: [SessionKey: SessionActivity] = [:],
    now: Date = PreviewFixtures.now
  ) {
    self.id = id
    self.title = title
    self.state = state
    self.hostList = hostList
    self.searchText = searchText
    self.selection = selection
    self.activities = activities
    self.now = now
  } // End of init(id:title:state:hostList:searchText:selection:activities:now:)
}

/// Every popover state, built from synthetic data only: invented session names, made-up
/// destinations (`*.example`), a fake socket path and fixed ids and times. Nothing here comes
/// from a real tmux server, `hosts.json` or iTerm2, and building the fixtures runs nothing.
public enum PreviewFixtures {
  /// The fixed "now" of every fixture, so relative times always read the same.
  public static let now = Date(timeIntervalSince1970: 1_790_000_000)

  /// Saturno, an SSH host.
  public static let saturno = HostConfig(
    id: fixtureID(1), displayName: "Saturno", mode: .ssh, sshDestination: "saturno.example")
  /// Neptuno, This Mac.
  public static let neptuno = HostConfig(id: fixtureID(2), displayName: "Neptuno", mode: .local)
  /// Sirio, an SSH host.
  public static let sirio = HostConfig(
    id: fixtureID(3), displayName: "Sirio", mode: .ssh, sshDestination: "sirio.example")

  /// A fixed host id.
  static func fixtureID(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
  }

  /// A synthetic session on `host`: session id `$<id>`, a fake server, `clients` control
  /// clients and, with `openHere`, one iTerm2 connection from the attachment index.
  public static func session(
    _ name: String,
    id: Int,
    on host: HostConfig,
    windows: Int,
    clients: Int = 0,
    openHere: Bool = false
  ) -> HostSnapshot.Session {
    let server = ServerIdentity(
      socketPath: "/tmp/tmux-fixture/default", pid: 4_000 + Int32(id), startTime: 1_789_990_000)
    let key = SessionKey(hostID: host.id, server: server, sessionID: TmuxSessionID("$\(id)")!)
    let discovered = DiscoveredSession(
      key: key,
      name: name,
      createdAt: 1_789_990_000,
      windowCount: windows,
      attachedClientCount: clients,
      lastActivityAt: 1_789_999_000,
      clients: (0..<clients).map { ClientSummary(pid: 9_000 + Int32($0), isControlMode: true) })
    let attachments =
      openHere
      ? [AttachmentSnapshot.Attachment(key: key, connectionID: "fixture", owningSessionID: "f")]
      : []
    return HostSnapshot.Session(discovered: discovered, attachments: attachments)
  } // End of static func session(_:id:on:windows:clients:openHere:)

  /// A snapshot of `host`: `outcome` `nil` means not checked yet; a failure keeps `sessions`
  /// as the last success's and marks them stale. Times are seconds before `now`.
  public static func snapshot(
    _ host: HostConfig,
    outcome: HostSnapshot.Outcome?,
    sessions: [HostSnapshot.Session] = [],
    lastSuccessAgo: TimeInterval? = nil,
    lastAttemptAgo: TimeInterval? = nil,
    isRefreshing: Bool = false
  ) -> HostSnapshot {
    var snapshot = HostSnapshot(host: host, configRevision: 1)
    snapshot.lastOutcome = outcome
    snapshot.sessions = sessions
    snapshot.lastSuccess = lastSuccessAgo.map { now.addingTimeInterval(-$0) }
    snapshot.lastAttempt = (lastAttemptAgo ?? lastSuccessAgo).map { now.addingTimeInterval(-$0) }
    snapshot.isRefreshing = isRefreshing
    switch outcome {
    case nil:
      snapshot.freshness = .notChecked
    case .sessionsListed, .noServer:
      snapshot.freshness = .live
      snapshot.nodeName = host.displayName.lowercased() + ".fixture"
    case .failed:
      snapshot.freshness = .stale
      snapshot.consecutiveFailures = 2
    }
    return snapshot
  } // End of static func snapshot(_:outcome:sessions:lastSuccessAgo:lastAttemptAgo:isRefreshing:)

  /// An engine state over `hosts` with the popover visible.
  public static func state(
    _ hosts: [HostSnapshot],
    attachmentCheck: AttachmentCheck = .checked(at: now, counts: .init(mapped: 1))
  ) -> RefreshState {
    RefreshState(
      hosts: hosts, attachmentCheck: attachmentCheck, configRevision: 1, isPopoverVisible: true,
      isAsleep: false)
  }

  // MARK: - Shared sessions

  /// Saturno's sessions: one open in iTerm2 here, one detached.
  static let saturnoSessions = [
    session("build-farm", id: 1, on: saturno, windows: 4, clients: 1, openHere: true),
    session("experiments", id: 2, on: saturno, windows: 2),
  ]
  /// Neptuno's sessions.
  static let neptunoSessions = [
    session("notes", id: 3, on: neptuno, windows: 1),
    session("index-rebuild", id: 4, on: neptuno, windows: 3, clients: 2),
  ]
  /// Sirio's sessions from its last success.
  static let sirioSessions = [
    session("thesis-draft", id: 5, on: sirio, windows: 2, clients: 1),
    session("photo-export", id: 6, on: sirio, windows: 1),
  ]

  /// Saturno, Neptuno (This Mac) and Sirio (unreachable, its sessions stale).
  static let overviewHosts = [
    snapshot(saturno, outcome: .sessionsListed, sessions: saturnoSessions, lastSuccessAgo: 20),
    snapshot(neptuno, outcome: .sessionsListed, sessions: neptunoSessions, lastSuccessAgo: 120),
    snapshot(
      sirio, outcome: .failed(.unreachable(.timeout)), sessions: sirioSessions,
      lastSuccessAgo: 180, lastAttemptAgo: 10),
  ]

  // MARK: - Fixtures

  /// Live hosts, This Mac, an unreachable host with stale sessions, the "Open in iTerm2 here"
  /// badge and a keyboard selection.
  public static let overview = PreviewFixture(
    id: "overview", title: "Hosts and sessions", state: state(overviewHosts),
    selection: saturnoSessions[1].key)

  /// "Opening…", "Waiting for iTerm2…", "Waiting for you in iTerm2" and a failure with Retry.
  public static let progress: PreviewFixture = {
    let sessions = [
      session("api-server", id: 7, on: saturno, windows: 2),
      session("build-farm", id: 1, on: saturno, windows: 4, clients: 1),
      session("experiments", id: 2, on: saturno, windows: 2),
      session("scratch", id: 8, on: saturno, windows: 1),
    ]
    let hosts = [
      snapshot(saturno, outcome: .sessionsListed, sessions: sessions, lastSuccessAgo: 5),
      snapshot(
        neptuno, outcome: .sessionsListed, sessions: [neptunoSessions[0]], lastSuccessAgo: 5),
    ]
    let activities: [SessionKey: SessionActivity] = [
      sessions[0].key: SessionActivity(.requested)!,
      sessions[1].key: SessionActivity(.launched(sessionID: "fixture"))!,
      sessions[2].key: SessionActivity(.stillWaiting(sessionID: "fixture"))!,
      sessions[3].key: SessionActivity(.failed(.timedOut))!,
    ]
    return PreviewFixture(
      id: "progress", title: "Progress and errors", state: state(hosts), activities: activities)
  }()

  /// "Sign-in needed", "tmux not found" and "Host key problem", each with Retry.
  public static let hostProblems = PreviewFixture(
    id: "host-problems", title: "Host problems",
    state: state([
      snapshot(saturno, outcome: .failed(.authFailed), lastAttemptAgo: 30),
      snapshot(neptuno, outcome: .failed(.tmuxNotFound), lastAttemptAgo: 30),
      snapshot(
        sirio, outcome: .failed(.hostKeyProblem(.unknown)), sessions: sirioSessions,
        lastSuccessAgo: 3_600 * 26, lastAttemptAgo: 30),
    ]))

  /// "Checking…", This Mac with no sessions and an SSH host with "No sessions".
  public static let checkingAndEmpty = PreviewFixture(
    id: "checking-empty", title: "Checking and empty hosts",
    state: state([
      snapshot(saturno, outcome: nil, isRefreshing: true),
      snapshot(neptuno, outcome: .noServer, lastSuccessAgo: 40),
      snapshot(sirio, outcome: .sessionsListed, lastSuccessAgo: 3_600 * 2, isRefreshing: true),
    ]))

  /// A search matching one session on each host.
  public static let search = PreviewFixture(
    id: "search", title: "Search", state: state(overviewHosts), searchText: "ex",
    selection: neptunoSessions[1].key)

  /// A search matching nothing.
  public static let noMatches = PreviewFixture(
    id: "no-matches", title: "Search with no matches", state: state(overviewHosts),
    searchText: "zebra")

  /// No host turned on (the onboarding examples start turned off).
  public static let noHosts = PreviewFixture(
    id: "no-hosts", title: "No hosts turned on", state: state([], attachmentCheck: .notChecked),
    hostList: .notSavedYet)

  /// An unusable `hosts.json`: left as it is, the examples (all off) in its place.
  public static let invalidHostList = PreviewFixture(
    id: "invalid-host-list", title: "Unusable host list",
    state: state([], attachmentCheck: .notChecked), hostList: .invalid(.notJSON))

  /// A failed iTerm2 check (badges unknown, never "not open here") and "Check failed".
  public static let iTermCheckFailed = PreviewFixture(
    id: "iterm2-check-failed", title: "iTerm2 check failed",
    state: state(
      [
        snapshot(
          saturno, outcome: .sessionsListed,
          sessions: saturnoSessions.map { HostSnapshot.Session(discovered: $0.discovered) },
          lastSuccessAgo: 15),
        snapshot(
          sirio, outcome: .failed(.probeError("The discovery output could not be read.")),
          lastAttemptAgo: 15),
      ],
      attachmentCheck: .failed(at: now, error: .apiDisabled)))

  /// The host list still loading.
  public static let loading = PreviewFixture(
    id: "loading", title: "Loading", state: nil, hostList: nil)

  /// Every fixture, in the preview window's order.
  public static let all = [
    overview, progress, hostProblems, checkingAndEmpty, search, noMatches, noHosts,
    invalidHostList, iTermCheckFailed, loading,
  ]
}
