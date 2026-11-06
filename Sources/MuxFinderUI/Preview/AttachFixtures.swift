import Foundation
import MuxFinderCore

/// The session actions' states for `--preview-fixtures --preview-gallery attach` (PLAN.md
/// D25): progress and results, every failure with its recoveries, the Move here dialog, Detach,
/// Detach other clients (its two dialogs, its progress, results and failures, PLAN.md D37) and
/// the banners. The New session form's states (empty, invalid name, creating, collision,
/// failed, a folder dragged over Directory; its directory list open with entries, with nothing
/// to pick, with the directory saved already, with an unusable file, filtered by typing and
/// with no matching directory, D31) are `newSessionStates`: the form is in its own window now
/// (D34), whose gallery (`--preview-gallery new-session`) shows them, not the attach gallery.
/// Synthetic data only (invented session names and paths, `*.example` destinations, a fake
/// socket path, fixed ids); building them runs nothing.
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

  /// A synthetic session on Saturno open here once, with `clients` tmux clients.
  static func openHere(_ name: String, id: Int, clients: Int) -> HostSnapshot.Session {
    Fixtures.session(
      name, id: id, on: Fixtures.saturno, windows: 1 + id % 3, clients: clients, openHere: true)
  }

  /// The "Detach other clients…" confirmation (`otherClients` others, `here` of them in this
  /// Mac's iTerm2) for a session of Saturno open here.
  static func detachOtherClientsFixture(
    id: String,
    title: String,
    otherClients: Int,
    here: Int
  ) -> PreviewFixture {
    var session = openHere("build-farm", id: 32 + otherClients, clients: otherClients + 1)
    for extra in 0..<here {
      session.attachments.append(
        AttachmentSnapshot.Attachment(
          key: session.key, connectionID: "fixture-\(extra)", owningSessionID: "g\(extra)"))
    }
    return PreviewFixture(
      id: id, title: title, state: hosts(saturno: [session]),
      panel: .detachOtherClients(
        DetachOtherClientsRequest(
          target: AttachTarget(host: Fixtures.saturno, session: session.discovered),
          otherClients: otherClients, otherClientsHere: here)))
  } // End of static func detachOtherClientsFixture(id:title:otherClients:here:)

  /// The "Detach other clients…" confirmation for a session with one other client.
  public static let detachOtherClients = detachOtherClientsFixture(
    id: "attach-detach-other-clients", title: "Detach other clients", otherClients: 1, here: 0)

  /// The confirmation for two other clients, one of them a second attachment in this Mac's
  /// iTerm2.
  public static let detachOtherClientsHere = detachOtherClientsFixture(
    id: "attach-detach-other-clients-here", title: "Detach other clients: one also here",
    otherClients: 2, here: 1)

  /// "Detaching other clients…" (the row with the badge's "also attached elsewhere"), one and
  /// two detached (one had already left) and nothing left to detach.
  public static let detachOtherClientsResults: PreviewFixture = {
    let sessions = [
      openHere("api-server", id: 110, clients: 2), openHere("build-farm", id: 111, clients: 1),
      openHere("experiments", id: 112, clients: 1), openHere("scratch", id: 113, clients: 1),
    ]
    let activities: [SessionKey: SessionActivity] = [
      sessions[0].key: .detachingOtherClients,
      sessions[1].key: .detachedOtherClients(count: 1, alreadyLeft: 0),
      sessions[2].key: .detachedOtherClients(count: 2, alreadyLeft: 1),
      sessions[3].key: .noOtherClientsLeft,
    ]
    return PreviewFixture(
      id: "attach-detach-other-clients-results", title: "Detach other clients: results",
      state: hosts(saturno: sessions), activities: activities)
  }()

  /// The problem a "Detach other clients…" that ended `outcome` shows.
  static func otherClientsProblem(_ outcome: DetachOtherClientsResult.Outcome) -> SessionProblem {
    let key = Fixtures.session("fixture", id: 119, on: Fixtures.saturno, windows: 1).key
    return SessionProblem.detachOtherClients(DetachOtherClientsResult(key: key, outcome: outcome))!
  }

  /// Not attached here any more, this Mac's tab changed, and a detach tmux refused, each with
  /// "Refresh".
  public static let detachOtherClientsProblems = failures(
    id: "attach-detach-other-clients-problems", title: "Detach other clients: problems",
    [
      ("api-server", otherClientsProblem(.notAttachedHere)),
      ("build-farm", otherClientsProblem(.identityChanged)),
      ("experiments", otherClientsProblem(.checkFailed(.send(.tmuxCommandFailed)))),
    ])

  /// A failed check (with the Python API fix-it), a send that failed, and a confirmation for
  /// another session.
  public static let detachOtherClientsCheckFailures = failures(
    id: "attach-detach-other-clients-check-failures", title: "Detach other clients: failures",
    [
      (
        "scratch",
        otherClientsProblem(.checkFailed(.attachmentCheck(.attachmentCheckFailed(.apiDisabled))))
      ),
      ("release-check", otherClientsProblem(.checkFailed(.send(.timedOut)))),
      ("docs-site", otherClientsProblem(.notConfirmed)),
    ])

  /// The New session form, empty, for This Mac.
  public static let newSession = PreviewFixture(
    id: "new-session", title: "New session", state: hosts(saturno: [], neptuno: neptuno),
    showsNewSession: true, newSessionDraft: NewSessionDraft(hostID: Fixtures.neptuno.id))

  /// The form with a name tmux would change, shown inline.
  public static let newSessionInvalid = PreviewFixture(
    id: "new-session-invalid", title: "New session: invalid name",
    state: hosts(saturno: [], neptuno: neptuno), showsNewSession: true,
    newSessionDraft: NewSessionDraft(
      hostID: Fixtures.neptuno.id, name: "logs:old", directory: "~/projects"))

  /// The form while the session is created and opened.
  public static let newSessionCreating: PreviewFixture = {
    var draft = NewSessionDraft(hostID: Fixtures.saturno.id, name: "experiments-2")
    draft.state = .creating
    return PreviewFixture(
      id: "new-session-creating", title: "New session: creating",
      state: hosts(saturno: [], neptuno: neptuno), showsNewSession: true, newSessionDraft: draft)
  }()

  /// The form after a collision, offering "Open existing".
  public static let newSessionCollision: PreviewFixture = {
    var draft = NewSessionDraft(hostID: Fixtures.neptuno.id, name: "notes")
    draft.state = .collision
    return PreviewFixture(
      id: "new-session-collision", title: "New session: name taken",
      state: hosts(saturno: [], neptuno: neptuno), showsNewSession: true, newSessionDraft: draft)
  }()

  /// The form after a creation that failed (the folder is missing on the host), shown in the
  /// window under the fields.
  public static let newSessionFailed: PreviewFixture = {
    var draft = NewSessionDraft(
      hostID: Fixtures.saturno.id, name: "site-preview", directory: "~/projects/archive")
    draft.state = .failed(SessionCreationError.directoryMissing.message)
    return PreviewFixture(
      id: "new-session-failed", title: "New session: creation failed",
      state: hosts(saturno: [], neptuno: neptuno), showsNewSession: true, newSessionDraft: draft)
  }()

  /// A folder dragged from Finder over the Directory field, which shows its drop highlight
  /// (PLAN.md D34, Phase I-9b); the field still holds what was typed before.
  public static let newSessionFolderDrag = PreviewFixture(
    id: "new-session-folder-drag", title: "New session: folder dragged over Directory",
    state: hosts(saturno: [], neptuno: neptuno), showsNewSession: true,
    newSessionDraft: NewSessionDraft(
      hostID: Fixtures.neptuno.id, name: "site-preview", directory: "~/projects"),
    directoryDropTargeted: true)

  // MARK: - New session's directory list (PLAN.md D31)

  /// A synthetic session on `host` that started in `folder` (`nil`: none reported).
  static func session(
    _ name: String, id: Int, on host: HostConfig, startedIn folder: String?
  ) -> HostSnapshot.Session {
    var session = Fixtures.session(name, id: id, on: host, windows: 1)
    session.discovered.startDirectory = folder
    return session
  }

  /// Saturno's sessions with their start folders: two in one folder, one without any.
  static let saturnoFolderSessions = [
    session("api-server", id: 101, on: Fixtures.saturno, startedIn: "/Users/example/projects/api"),
    session("api-tests", id: 102, on: Fixtures.saturno, startedIn: "/Users/example/projects/api"),
    session("site", id: 103, on: Fixtures.saturno, startedIn: "/Users/example/projects/site"),
    session("scratch", id: 104, on: Fixtures.saturno, startedIn: nil),
  ]

  /// This Mac's sessions with their start folders, for the filtered list: one in a projects
  /// folder (which `~/proj` finds through the `~` rule), one elsewhere.
  static let neptunoFolderSessions = [
    session("notes", id: 105, on: Fixtures.neptuno, startedIn: "/Users/example/projects/site"),
    session(
      "journal", id: 106, on: Fixtures.neptuno, startedIn: "/Users/example/Documents/journal"),
  ]

  /// The directory lists of the picker fixtures: three saved directories (one long enough to
  /// be shortened in the middle), Saturno's two recent ones and This Mac's one.
  static let directoryLists = DirectoryLists(
    saved: [
      "~/projects/site", "~/projects/api",
      "~/Documents/client work/2026/quarterly reports/drafts/final",
    ],
    recent: [
      Fixtures.saturno.id: ["~/projects/experiments", "~/scratch"],
      Fixtures.neptuno.id: ["~/notes"],
    ])

  /// The lists of the filter fixtures: the picker fixtures' with a second recent directory for
  /// This Mac, in a projects folder.
  static let filterLists = DirectoryLists(
    saved: directoryLists.saved,
    recent: [
      Fixtures.saturno.id: directoryLists.recent(for: Fixtures.saturno.id),
      Fixtures.neptuno.id: ["~/projects/blog", "~/notes"],
    ])

  /// A New session fixture with its directory list open (`opening`: by the button, or by
  /// typing), over Saturno's folder sessions and `neptunoSessions`.
  static func directoryFixture(
    id: String,
    title: String,
    draft: NewSessionDraft,
    lists: DirectoryLists,
    status: DirectoryListStatus = .usable(droppedEntryCount: 0),
    highlighted: DirectoryPickerContent.Item? = nil,
    opening: DirectoryPickerState.Opening = .request,
    neptunoSessions: [HostSnapshot.Session] = neptuno
  ) -> PreviewFixture {
    PreviewFixture(
      id: id, title: title,
      state: hosts(saturno: saturnoFolderSessions, neptuno: neptunoSessions),
      showsNewSession: true, newSessionDraft: draft, directoryLists: lists,
      directoryStatus: status,
      directoryPicker: DirectoryPickerState(opening: opening, highlighted: highlighted))
  } // End of func directoryFixture(id:title:draft:lists:status:highlighted:opening:…)

  /// Saturno's list: "Recent", "Saved" and "Sessions on Saturno" (one folder per two
  /// sessions), the first recent directory highlighted, "Save this directory" off (the field is
  /// empty).
  public static let newSessionDirectories = directoryFixture(
    id: "new-session-directories", title: "New session: directory list",
    draft: NewSessionDraft(hostID: Fixtures.saturno.id, name: "site-preview"),
    lists: directoryLists, highlighted: .entry(.recent, "~/projects/experiments"))

  /// This Mac with nothing saved, recorded or reported yet: the list says so; "Save this
  /// directory" is on for the typed directory.
  public static let newSessionNothingToPick = directoryFixture(
    id: "new-session-nothing-to-pick", title: "New session: nothing to pick yet",
    draft: NewSessionDraft(
      hostID: Fixtures.neptuno.id, name: "new-app", directory: "~/projects/new-app"),
    lists: DirectoryLists(), highlighted: .action(.saveDirectory))

  /// This Mac with the typed directory saved already: "Save this directory" is off, and the
  /// filter keeps that saved entry (an exact match).
  public static let newSessionSavedAlready = directoryFixture(
    id: "new-session-saved-already", title: "New session: directory saved already",
    draft: NewSessionDraft(
      hostID: Fixtures.neptuno.id, name: "site", directory: "~/projects/site"),
    lists: directoryLists, highlighted: .entry(.saved, "~/projects/site"))

  /// A directory list file muxFinder can't use: the list shows why, and offers no change.
  public static let newSessionUnusableFile = directoryFixture(
    id: "new-session-unusable-file", title: "New session: unusable directory list",
    draft: NewSessionDraft(hostID: Fixtures.saturno.id, name: "site-preview"),
    lists: DirectoryLists(), status: .fileNotUsable(.unsafe(.permissionsTooOpen)))

  /// This Mac with `~/proj` typed: the list opened by the typing, nothing highlighted, keeps the
  /// matching recent and saved directories and the session folder `/Users/example/projects/site`
  /// (the `~` rule; `/Users/example` is the fixtures' home folder).
  public static let newSessionFiltered = directoryFixture(
    id: "new-session-filtered", title: "New session: typing filters the list",
    draft: NewSessionDraft(hostID: Fixtures.neptuno.id, name: "site-preview", directory: "~/proj"),
    lists: filterLists, opening: .typing, neptunoSessions: neptunoFolderSessions)

  /// Saturno with a directory typed that no entry contains, the list opened with the button:
  /// "No matching directories" above the actions, both on.
  public static let newSessionNoMatches = directoryFixture(
    id: "new-session-no-matches", title: "New session: no matching directories",
    draft: NewSessionDraft(
      hostID: Fixtures.saturno.id, name: "site-preview", directory: "~/archive/2019"),
    lists: directoryLists)

  /// A session that vanished and one that changed between the listing and Open.
  public static let banners = PreviewFixture(
    id: "attach-banners", title: "Vanished and changed sessions",
    state: hosts(saturno: saturnoSessions(["api-server", "build-farm"], first: 90)),
    banners: [
      SessionBanner(id: 2, kind: .changed, sessionName: "experiments", hostName: "Saturno"),
      SessionBanner(id: 1, kind: .vanished, sessionName: "scratch", hostName: "Saturno"),
    ])

  /// This Mac's sessions in the New session fixtures.
  static let neptuno = [Fixtures.session("notes", id: 95, on: Fixtures.neptuno, windows: 1)]

  /// Two rows for the context menu's card: one open in iTerm2 here and attached elsewhere too
  /// (Detach and Detach other clients offered, Move here not), one attached elsewhere (Move
  /// here offered, neither detach).
  public static let menuRows: [SessionRow] = {
    let content = PopoverContent(
      state: hosts(
        saturno: [
          Fixtures.session(
            "build-farm", id: 97, on: Fixtures.saturno, windows: 4, clients: 2, openHere: true),
          Fixtures.session("experiments", id: 98, on: Fixtures.saturno, windows: 2, clients: 1),
        ]),
      hostList: .saved, query: "", activities: [:], selection: nil, now: Fixtures.now)
    return content.sections.flatMap(\.rows)
  }()

  /// Every fixture of the popover's session actions, in the gallery's order.
  public static let all = [
    progress, launchFailures, moreLaunchFailures, checkFailures, moreCheckFailures, hostFailures,
    iTermFailures, moveHere, detach, detachProblems, detachOtherClients, detachOtherClientsHere,
    detachOtherClientsResults, detachOtherClientsProblems, detachOtherClientsCheckFailures,
    banners,
  ]

  /// The New session form's states as the popover opens it (the New session window's, PLAN.md
  /// D34), in the order of the window's gallery (`NewSessionGallery`, which adds the switcher's
  /// `SwitcherFixtures.form`): editing, the directory list's states, busy, the collision, the
  /// failure and the drop highlight. Not in the attach gallery, whose popovers no longer show
  /// the form.
  public static let newSessionStates = [
    newSession, newSessionInvalid, newSessionDirectories, newSessionNothingToPick,
    newSessionSavedAlready, newSessionUnusableFile, newSessionFiltered, newSessionNoMatches,
    newSessionCreating, newSessionCollision, newSessionFailed, newSessionFolderDrag,
  ]
}
