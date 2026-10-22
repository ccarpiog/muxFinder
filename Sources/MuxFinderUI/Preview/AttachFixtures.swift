import Foundation
import MuxFinderCore

/// The session actions' states for `--preview-fixtures --preview-gallery attach` (PLAN.md
/// D25): progress and results, every failure with its recoveries, the Move here dialog, Detach,
/// the New session sheet (empty, invalid name, creating, collision) and the banners. Synthetic
/// data only (invented session names, `*.example` destinations, a fake socket path, fixed ids);
/// building them runs nothing.
public enum AttachFixtures {
  /// Shorthand.
  typealias Fixtures = PreviewFixtures

  /// A launch tab id for the fixtures.
  static let launchTab = "fixture-launch-tab"

  /// Saturno (SSH) and Neptuno (This Mac), live, with `saturno` and `neptuno` as sessions.
  static func hosts(
    saturno: [HostSnapshot.Session],
    neptuno: [HostSnapshot.Session] = []
  ) -> RefreshState {
    var snapshots = [
      Fixtures.snapshot(
        Fixtures.saturno, outcome: .sessionsListed, sessions: saturno, lastSuccessAgo: 5)
    ]
    if !neptuno.isEmpty {
      snapshots.append(
        Fixtures.snapshot(
          Fixtures.neptuno, outcome: .sessionsListed, sessions: neptuno, lastSuccessAgo: 5))
    }
    return Fixtures.state(snapshots)
  } // End of static func hosts(saturno:neptuno:)

  /// Synthetic sessions on Saturno, numbered from `first`.
  static func saturnoSessions(_ names: [String], first: Int) -> [HostSnapshot.Session] {
    names.enumerated().map { offset, name in
      Fixtures.session(name, id: first + offset, on: Fixtures.saturno, windows: 1 + offset % 3)
    }
  }

  /// A failure fixture: one Saturno session per failure, each row showing its problem.
  static func failures(
    id: String,
    title: String,
    _ failures: [(String, SessionProblem)]
  ) -> PreviewFixture {
    let sessions = saturnoSessions(failures.map(\.0), first: 40 + id.count * 10)
    var activities: [SessionKey: SessionActivity] = [:]
    for (session, failure) in zip(sessions, failures) {
      activities[session.key] = .failed(failure.1)
    }
    return PreviewFixture(
      id: id, title: title, state: hosts(saturno: sessions), activities: activities)
  } // End of static func failures(id:title:_:)

  // MARK: - Fixtures

  /// "Opening…", "Moving here…", "Waiting for iTerm2…", "Still connecting — check the iTerm2
  /// tab" with "Show tab" (and the note after a "Show tab" that did nothing), "Confirmed…" and
  /// "Already open here…".
  public static let progress: PreviewFixture = {
    let sessions = saturnoSessions(
      ["api-server", "build-farm", "experiments", "scratch", "release-check"], first: 20)
    let local = [Fixtures.session("notes", id: 26, on: Fixtures.neptuno, windows: 1, clients: 1)]
    let activities: [SessionKey: SessionActivity] = [
      sessions[0].key: .opening,
      sessions[1].key: .movingHere,
      sessions[2].key: .waitingForITerm2,
      sessions[3].key: .stillConnecting(launchTabID: launchTab),
      sessions[4].key: .confirmed,
      local[0].key: .focused,
    ]
    return PreviewFixture(
      id: "attach-progress", title: "Opening and results",
      state: hosts(saturno: sessions, neptuno: local), activities: activities,
      notes: [
        sessions[3].key: SessionProblem.showTabNote(.failed(.activateFailed(.badIdentifier)))!
      ],
      attachedHere: [
        sessions[4].key: AttachmentRecord(connectionID: "fixture", gatewaySessionID: launchTab)
      ])
  }()

  /// Failures after the launch tab opened, with "Show tab" where the tab explains more.
  public static let launchFailures = failures(
    id: "attach-launch-failures", title: "Launch failures",
    [
      ("api-server", .attach(.timedOut, launchTab: launchTab)),
      ("build-farm", .attach(.helperFailed(.sshFailed(.authFailed)), launchTab: launchTab)),
      ("experiments", .attach(.waitLimitReached, launchTab: launchTab)),
    ])

  /// More launch failures: tmux ended, an unreadable identity answer, the launch folder.
  public static let moreLaunchFailures = failures(
    id: "attach-more-launch-failures", title: "More launch failures",
    [
      ("scratch", .attach(.helperEnded)),
      ("release-check", .attach(.identityCheckFailed(nil))),
      ("docs-site", .attach(.launchStore(.directoryNotOwnedByUser))),
    ])

  /// The existing-attachment check's refusals: already open here (with "Bring forward" and
  /// "Detach from this Mac"), possibly open here, an earlier launch; and a session open here
  /// whose tab did not come forward (no tab appeared).
  public static let checkFailures = failures(
    id: "attach-check-failures", title: "Already open here",
    [
      ("api-server", .attach(.alreadyAttachedHere(connectionID: "fixture", owningSessionID: "f"))),
      ("build-farm", .attach(.possiblyAttachedHere(unresolved: 1))),
      ("experiments", .attach(.earlierLaunchPending)),
      ("ml-training", .notBroughtForward(nil)),
    ])

  /// A failed or changed check, a confirmation for another session, and a session open here
  /// whose tab iTerm2 did not bring forward.
  public static let moreCheckFailures = failures(
    id: "attach-more-check-failures", title: "Check failures",
    [
      ("scratch", .attach(.attachmentCheckFailed(.apiDisabled))),
      ("release-check", .attach(.attachmentChanged)),
      ("docs-site", .attach(.moveHereNotConfirmed)),
      ("photo-export", .notBroughtForward(.activateFailed(.badIdentifier))),
    ])

  /// Host and tmux problems, with "Open Settings".
  public static let hostFailures = failures(
    id: "attach-host-failures", title: "Host problems",
    [
      ("api-server", .attach(.invalidDestination(.sshDestinationContainsWhitespace))),
      ("build-farm", .attach(.tmuxMissing)),
      ("experiments", .attach(.discoveryFailed("unreachable"))),
    ])

  /// iTerm2 refusing (with the Automation fix-it), a cancelled attach, the missing helper.
  public static let iTermFailures = failures(
    id: "attach-iterm2-failures", title: "iTerm2 and helper problems",
    [
      ("scratch", .attach(.iTerm2(.automationDenied))),
      ("release-check", .attach(.cancelled)),
      ("docs-site", .unavailable(LaunchHelperPathError.notFound.message)),
    ])

  /// The Move here confirmation for a session two clients use.
  public static let moveHere: PreviewFixture = {
    let session = Fixtures.session(
      "build-farm", id: 30, on: Fixtures.saturno, windows: 4, clients: 2)
    return PreviewFixture(
      id: "attach-move-here", title: "Move here", state: hosts(saturno: [session]),
      panel: .moveHere(
        MoveHereRequest(
          target: AttachTarget(host: Fixtures.saturno, session: session.discovered))))
  }()

  /// A detach fixture: Saturno's sessions `names` with the activities `activities` builds from
  /// a detach problem maker, plus `extra` sessions.
  static func detachFixture(
    id: String,
    title: String,
    names: [String],
    first: Int,
    extra: [HostSnapshot.Session] = [],
    _ activities: ([SessionKey], (SessionDetachResult.Outcome, AttachFailure?) -> SessionActivity)
      -> [SessionKey: SessionActivity]
  ) -> PreviewFixture {
    let sessions = saturnoSessions(names, first: first)
    let key = sessions[0].key
    let problem = { (outcome: SessionDetachResult.Outcome, failure: AttachFailure?) in
      SessionActivity.failed(
        SessionProblem.detach(
          SessionDetachResult(key: key, outcome: outcome, checkFailure: failure))!)
    }
    return PreviewFixture(
      id: id, title: title, state: hosts(saturno: sessions + extra),
      activities: activities(sessions.map(\.key), problem))
  } // End of static func detachFixture(id:title:names:first:extra:_:)

  /// "Detaching…", "Detached…", nothing to detach, a cancelled detach, and a session open here
  /// (its badge).
  public static let detach = detachFixture(
    id: "attach-detach", title: "Detach from this Mac",
    names: ["api-server", "build-farm", "experiments", "scratch"], first: 70,
    extra: [
      Fixtures.session(
        "photo-export", id: 76, on: Fixtures.saturno, windows: 1, clients: 1, openHere: true)
    ]
  ) { keys, problem in
    [
      keys[0]: .detaching, keys[1]: .detached, keys[2]: problem(.nothingAttached, nil),
      keys[3]: problem(.cancelled, nil),
    ]
  }

  /// Detaches that did not detach: nothing sent, not closed, the check failed.
  public static let detachProblems = detachFixture(
    id: "attach-detach-problems", title: "Detach problems",
    names: ["release-check", "docs-site", "ml-training"], first: 80
  ) { keys, problem in
    [
      keys[0]: problem(.notSent, nil), keys[1]: problem(.notClosed, nil),
      keys[2]: problem(.checkFailed, .attachmentCheckFailed(.timedOut)),
    ]
  }

  /// The New session sheet, empty, for This Mac.
  public static let newSession = PreviewFixture(
    id: "new-session", title: "New session", state: hosts(saturno: [], neptuno: neptuno),
    panel: .newSession, newSessionDraft: NewSessionDraft(hostID: Fixtures.neptuno.id))

  /// The sheet with a name tmux would change, shown inline.
  public static let newSessionInvalid = PreviewFixture(
    id: "new-session-invalid", title: "New session: invalid name",
    state: hosts(saturno: [], neptuno: neptuno), panel: .newSession,
    newSessionDraft: NewSessionDraft(
      hostID: Fixtures.neptuno.id, name: "logs:old", directory: "~/projects"))

  /// The sheet while the session is created and opened.
  public static let newSessionCreating: PreviewFixture = {
    var draft = NewSessionDraft(hostID: Fixtures.saturno.id, name: "experiments-2")
    draft.state = .creating
    return PreviewFixture(
      id: "new-session-creating", title: "New session: creating",
      state: hosts(saturno: [], neptuno: neptuno), panel: .newSession, newSessionDraft: draft)
  }()

  /// The sheet after a collision, offering "Open existing".
  public static let newSessionCollision: PreviewFixture = {
    var draft = NewSessionDraft(hostID: Fixtures.neptuno.id, name: "notes")
    draft.state = .collision
    return PreviewFixture(
      id: "new-session-collision", title: "New session: name taken",
      state: hosts(saturno: [], neptuno: neptuno), panel: .newSession, newSessionDraft: draft)
  }()

  /// A session that vanished and one that changed between the listing and Open.
  public static let banners = PreviewFixture(
    id: "attach-banners", title: "Vanished and changed sessions",
    state: hosts(saturno: saturnoSessions(["api-server", "build-farm"], first: 90)),
    banners: [
      SessionBanner(id: 2, kind: .changed, sessionName: "experiments", hostName: "Saturno"),
      SessionBanner(id: 1, kind: .vanished, sessionName: "scratch", hostName: "Saturno"),
    ])

  /// This Mac's sessions in the sheet fixtures.
  static let neptuno = [Fixtures.session("notes", id: 95, on: Fixtures.neptuno, windows: 1)]

  /// Two rows for the context menu's card: one open in iTerm2 here (Detach offered, Move here
  /// not), one attached elsewhere (Move here offered, Detach not).
  public static let menuRows: [SessionRow] = {
    let content = PopoverContent(
      state: hosts(
        saturno: [
          Fixtures.session(
            "build-farm", id: 97, on: Fixtures.saturno, windows: 4, clients: 1, openHere: true),
          Fixtures.session("experiments", id: 98, on: Fixtures.saturno, windows: 2, clients: 1),
        ]),
      hostList: .saved, query: "", activities: [:], selection: nil, now: Fixtures.now)
    return content.sections.flatMap(\.rows)
  }()

  /// Every fixture, in the gallery's order.
  public static let all = [
    progress, launchFailures, moreLaunchFailures, checkFailures, moreCheckFailures, hostFailures,
    iTermFailures, moveHere, detach, detachProblems, newSession, newSessionInvalid,
    newSessionCreating, newSessionCollision, banners,
  ]
}
