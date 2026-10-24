import Foundation
import MuxFinderCore

/// The session switcher's states for `--preview-fixtures --preview-gallery switcher` (PLAN.md
/// D32, Phase I-3b): the list, a filtered list, New session with a name from the filter, the
/// form, an action in progress, a failure while it showed and one carried from a closed
/// switcher, no hosts turned on, and hosts checking or unreachable. Synthetic data only
/// (invented session names, `*.example` destinations, a fake socket path, fixed ids); building
/// them runs nothing.
public enum SwitcherFixtures {
  /// Shorthand.
  typealias Fixtures = PreviewFixtures

  /// A launch tab id for the fixtures.
  static let launchTab = "fixture-launch-tab"

  /// This Mac's sessions: one open in iTerm2 here, one attached elsewhere.
  static let neptunoSessions = [
    Fixtures.session(
      "notes", id: 201, on: Fixtures.neptuno, windows: 2, clients: 1, openHere: true),
    Fixtures.session("index-rebuild", id: 202, on: Fixtures.neptuno, windows: 3, clients: 2),
  ]
  /// Saturno's sessions: attached elsewhere, detached, detached.
  static let saturnoSessions = [
    Fixtures.session("build-farm", id: 203, on: Fixtures.saturno, windows: 4, clients: 1),
    Fixtures.session("experiments", id: 204, on: Fixtures.saturno, windows: 2),
    Fixtures.session("api-server", id: 205, on: Fixtures.saturno, windows: 1),
  ]
  /// Sirio's sessions from its last success (stale while it is unreachable).
  static let sirioSessions = [
    Fixtures.session("thesis-draft", id: 206, on: Fixtures.sirio, windows: 2, clients: 1)
  ]

  /// This Mac and Saturno, both answered.
  static let liveHosts = Fixtures.state([
    Fixtures.snapshot(
      Fixtures.neptuno, outcome: .sessionsListed, sessions: neptunoSessions, lastSuccessAgo: 10),
    Fixtures.snapshot(
      Fixtures.saturno, outcome: .sessionsListed, sessions: saturnoSessions, lastSuccessAgo: 10),
  ])

  // MARK: - Fixtures

  /// The live sessions of This Mac and Saturno, the first row selected, New session last.
  public static let list = PreviewFixture(
    id: "switcher-list", title: "Sessions", state: liveHosts)

  /// "ex" matches "index-rebuild" and "experiments"; New session offers the name "ex".
  public static let filtered = PreviewFixture(
    id: "switcher-filtered", title: "Filtered", state: liveHosts, switcherSearchText: "ex")

  /// A filter no session matches and that is a valid session name: New session offers it and
  /// is selected.
  public static let newSessionName = PreviewFixture(
    id: "switcher-new-session-name", title: "New session with a name",
    state: liveHosts, switcherSearchText: "deploy-docs")

  /// The New session form, its name filled in from the filter, for This Mac.
  public static let form = PreviewFixture(
    id: "switcher-form", title: "New session form", state: liveHosts, panel: .newSession,
    newSessionDraft: NewSessionDraft(hostID: Fixtures.neptuno.id, name: "deploy-docs"),
    directoryStatus: .usable(droppedEntryCount: 0))

  /// An Open in progress: "Waiting for iTerm2…" on the selected row.
  public static let opening = PreviewFixture(
    id: "switcher-opening", title: "Opening", state: liveHosts,
    activities: [saturnoSessions[1].key: .waitingForITerm2],
    switcherSelection: .session(saturnoSessions[1].key))

  /// An Open that failed while the switcher showed: the popover row's text and recoveries.
  public static let failure = PreviewFixture(
    id: "switcher-failure", title: "Failure", state: liveHosts,
    activities: [saturnoSessions[2].key: .failed(.attach(.timedOut, launchTab: launchTab))],
    switcherSelection: .session(saturnoSessions[2].key))

  /// An Open that failed after the switcher closed: pinned at the top of the next opening.
  public static let carriedFailure = PreviewFixture(
    id: "switcher-carried-failure", title: "Failure since the last opening", state: liveHosts,
    activities: [
      saturnoSessions[0].key: .failed(
        .attach(.helperFailed(.sshFailed(.authFailed)), launchTab: launchTab))
    ],
    switcherCarriedFailures: [saturnoSessions[0].key])

  /// No host turned on: the popover's placeholder with "Open Settings".
  public static let noHosts = PreviewFixture(
    id: "switcher-no-hosts", title: "No hosts turned on",
    state: Fixtures.state([], attachmentCheck: .notChecked), hostList: .notSavedYet)

  /// Saturno still checking and Sirio unreachable (its stale sessions left out): their muted
  /// lines under This Mac's sessions.
  public static let checkingAndUnreachable = PreviewFixture(
    id: "switcher-checking-unreachable", title: "Hosts checking or unreachable",
    state: Fixtures.state([
      Fixtures.snapshot(
        Fixtures.neptuno, outcome: .sessionsListed, sessions: neptunoSessions,
        lastSuccessAgo: 10),
      Fixtures.snapshot(Fixtures.saturno, outcome: nil, isRefreshing: true),
      Fixtures.snapshot(
        Fixtures.sirio, outcome: .failed(.unreachable(.timeout)), sessions: sirioSessions,
        lastSuccessAgo: 3_600, lastAttemptAgo: 20),
    ]))

  /// Every fixture, in the gallery's order.
  public static let all = [
    list, filtered, newSessionName, form, opening, failure, carriedFailure, noHosts,
    checkingAndUnreachable,
  ]
}
