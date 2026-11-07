import Foundation
import MuxFinderCore

/// The session actions' states per terminal for `--preview-gallery attach` (PLAN.md D38 *The UI
/// (I-12d2)*), after `AttachFixtures.all`: every `PlainTerminalWindowError` an Open can end in,
/// the plain backend's launch failures and refusals, the "earlier launch pending" refusal
/// naming the terminal that holds it, a plain Detach and its problems, "Detach other clients…"
/// stopped partway, the Move here and Detach other clients confirmations for a plain terminal,
/// the unavailable choice's lines, the notes of a window not brought forward, and the context
/// menus of Terminal and Ghostty ("Open in Terminal", "Show window", "Show in iTerm2", "Detach
/// (opened in iTerm2)"). Synthetic data only, as `TerminalSessionFixtures`; building them runs
/// nothing.
public enum TerminalAttachFixtures {
  /// Shorthand.
  typealias Sessions = TerminalSessionFixtures

  /// One row of a card: the session's name, what it shows, and the note under it.
  struct Row {
    /// The session's name.
    let name: String
    /// Its activity.
    let activity: SessionActivity
    /// The note under it, if any.
    var note: String?
  }

  /// How many rows a card holds, so no popover of the gallery scrolls.
  static let rowsPerCard = 3
  /// Session names, used in turn.
  static let names = [
    "api-server", "build-farm", "experiments", "scratch", "release-check", "docs-site",
    "ml-training", "photo-export", "site-preview", "index-rebuild", "notes", "logs",
  ]

  /// `rows` as cards of at most `rowsPerCard` Saturno sessions (with `clients` clients each,
  /// numbered from `first`), the terminal choice `choice`: ids `<id>-<n>`, titles "<title> (n of
  /// m)" when there is more than one card.
  static func cards(
    _ choice: TerminalChoiceResolution,
    id: String,
    title: String,
    first: Int,
    clients: Int = 0,
    _ rows: [Row]
  ) -> [PreviewFixture] {
    let chunks = stride(from: 0, to: rows.count, by: rowsPerCard).map {
      Array(rows[$0..<min($0 + rowsPerCard, rows.count)])
    }
    return chunks.enumerated().map { number, chunk in
      let sessions = chunk.enumerated().map { offset, row in
        PreviewFixtures.session(
          row.name, id: first + number * rowsPerCard + offset, on: PreviewFixtures.saturno,
          windows: 1 + offset, clients: clients)
      }
      var activities: [SessionKey: SessionActivity] = [:]
      var notes: [SessionKey: String] = [:]
      for (session, row) in zip(sessions, chunk) {
        activities[session.key] = row.activity
        notes[session.key] = row.note
      }
      let numbered = chunks.count > 1
      return Sessions.choosing(
        choice,
        PreviewFixture(
          id: numbered ? "\(id)-\(number + 1)" : id,
          title: numbered ? "\(title) (\(number + 1) of \(chunks.count))" : title,
          state: AttachFixtures.hosts(saturno: sessions), activities: activities, notes: notes))
    } // End of map over the cards
  } // End of static func cards(_:id:title:first:clients:_:)

  /// Rows of failures, one per problem, named in turn.
  static func failureRows(_ problems: [SessionProblem]) -> [Row] {
    problems.enumerated().map { Row(name: names[$0 % names.count], activity: .failed($1)) }
  }

  /// The problem of an Open whose window `error` stopped, in the terminal `loaded` names.
  static func window(
    _ error: PlainTerminalWindowError, in loaded: LoadedTerminalDefinition
  ) -> SessionProblem {
    .attach(.terminalWindow(error), wording: TerminalWording(definition: loaded.definition))
  }

  /// The problem of a plain attach that ended `failure` in Terminal, its window known.
  static func terminal(_ failure: AttachFailure) -> SessionProblem {
    .attach(failure, wording: Sessions.terminalWording, window: Sessions.terminalWindow)
  }

  /// The problem of a plain attach that ended `failure` in Ghostty, its window known.
  static func ghostty(_ failure: AttachFailure) -> SessionProblem {
    .attach(failure, wording: Sessions.ghosttyWording, window: Sessions.ghosttyWindow)
  }

  // MARK: - Opening a window

  /// The window errors shown for Terminal: the app gone, too old or of an unknown version, not
  /// allowed ("Open System Settings…"), not running and not opened; macOS not activating it, a
  /// refused launch command, the script not loading, the app not launched for the event, a
  /// handler's error and a call its script does not take.
  public static let terminalWindowErrors: [PlainTerminalWindowError] = [
    .appNotInstalled(appName: "Terminal"),
    .appTooOld(appName: "Terminal", installed: "1.9", minimum: "2.0"),
    .appVersionUnknown(appName: "Terminal", minimum: "2.0"), .permissionDenied(appName: "Terminal"),
    .appNotRunning(appName: "Terminal"), .activationFailed(appName: "Terminal"),
    .launchCommandRefused(.helperPathUnsafeForShellText),
    .scriptFailed(appName: "Terminal", .compileFailed(errorNumber: -2740)),
    .scriptFailed(appName: "Terminal", .callFailed(handler: .open, errorNumber: -600)),
    .scriptFailed(appName: "Terminal", .callFailed(handler: .open, errorNumber: -2700)),
    .scriptFailed(appName: "Terminal", .wrongArgumentCount(handler: .open)),
  ]

  /// The window errors shown for Ghostty: its AppleScript turned off, no script, an odd reply,
  /// a program that would not start, another terminal's window, a definition that changed; a
  /// window muxFinder did not open, one with no focus value or id, busy, gone, and an
  /// unattended run's refusal.
  public static let ghosttyWindowErrors: [PlainTerminalWindowError] = [
    .scriptFailed(appName: "Ghostty", .callFailed(handler: .open, errorNumber: -1708)),
    .scriptMissing(appName: "Ghostty"), .malformedReply(appName: "Ghostty", handler: .open),
    .spawnFailed(appName: "Ghostty", .spawnFailed(errno: 2)), .windowOfAnotherTerminal,
    .definitionChanged(appName: "Ghostty"), .notOpenedHere,
    .windowLacksFocusValue(appName: "Ghostty", .windowID), .windowHasNoID(appName: "Ghostty"),
    .windowBusy(appName: "Ghostty"), .windowGone(appName: "Ghostty"),
    .unattendedRunRefused(appName: "Ghostty", .notRunning),
  ]

  /// Terminal's window errors.
  public static let windowFailures = cards(
    .plain(Sessions.terminal), id: "terminals-window-failures",
    title: "Terminal: window failures", first: 400,
    failureRows(terminalWindowErrors.map { window($0, in: Sessions.terminal) }))

  /// Ghostty's window errors.
  public static let ghosttyWindowFailures = cards(
    .plain(Sessions.ghostty), id: "terminals-ghostty-window-failures",
    title: "Ghostty: window failures", first: 420,
    failureRows(ghosttyWindowErrors.map { window($0, in: Sessions.ghostty) }))

  // MARK: - Launches

  /// A window that did not attach in time, one whose helper stopped, one still waiting at the
  /// limit (each with "Show window"), no terminal device to check, the clients unreadable, an
  /// identity check unread.
  public static let launchFailures = cards(
    .plain(Sessions.terminal), id: "terminals-launch-failures",
    title: "Terminal: launch failures", first: 440,
    failureRows([
      terminal(.timedOut), terminal(.helperFailed(.sshFailed(.authFailed))),
      terminal(.waitLimitReached), terminal(.cannotConfirmHere),
      terminal(.clientCheckFailed(.sshFailed)), terminal(.identityCheckFailed(nil)),
    ]))

  /// A name plain tmux commands cannot check, a Move here refused for Ghostty's own window, an
  /// earlier Ghostty launch, and a different session reached.
  public static let refusals = cards(
    .plain(Sessions.ghostty), id: "terminals-refusals", title: "Ghostty: refusals", first: 450,
    [
      Row(name: "build[1]", activity: .failed(ghostty(.unsupportedSessionName))),
      Row(
        name: "api-server",
        activity: .failed(ghostty(.alreadyOpenInTerminal(window: Sessions.ghosttyWindow)))),
      Row(name: "experiments", activity: .failed(ghostty(.earlierLaunchPending))),
      Row(name: "scratch", activity: .failed(ghostty(.identityMismatch))),
    ])

  /// iTerm2 chosen: its own earlier launch (as before) beside one a Terminal launch holds and
  /// one a Ghostty launch holds.
  public static let earlierLaunch = cards(
    .iTerm2, id: "terminals-earlier-launch", title: "iTerm2: an earlier launch elsewhere",
    first: 460,
    failureRows([
      .attach(.earlierLaunchPending),
      .attach(.earlierLaunchPending, wording: Sessions.terminalWording),
      .attach(.earlierLaunchPending, wording: Sessions.ghosttyWording),
    ]))

  // MARK: - Detach and detach other clients

  /// A client record for the detach fixtures (invented values).
  static let client = PlainClientRecord(
    session: PlainClientRecord.identity(
      of: PreviewFixtures.session("fixture", id: 369, on: PreviewFixtures.saturno, windows: 1)
        .discovered),
    client: OtherClient(processID: "5150", created: "1789990100", name: "/dev/ttys041")!,
    launchID: LaunchToken(), token: nil, terminalPath: "/dev/ttys041")

  /// The key of the detach samples' results (the lines do not depend on it).
  static let sampleKey = PreviewFixtures.session(
    "fixture", id: 369, on: PreviewFixtures.saturno, windows: 1
  ).key

  /// The problem of a plain detach in Terminal that ended `outcome`.
  static func detachProblem(
    _ outcome: SessionDetachResult.Outcome, failure: PlainTmuxCommandFailure? = nil,
    check: AttachFailure? = nil
  ) -> SessionActivity {
    let result = SessionDetachResult(
      key: sampleKey, outcome: outcome, checkFailure: check,
      plainDetach: PlainDetachResult(client: client, failure: failure))
    return .failed(SessionProblem.detach(result, wording: Sessions.terminalWording)!)
  }

  /// A plain Detach's states: detaching, detached, and each problem.
  public static let detach = cards(
    .plain(Sessions.terminal), id: "terminals-detach", title: "Terminal: Detach from this Mac",
    first: 470,
    [
      Row(name: "api-server", activity: .detaching),
      Row(name: "build-farm", activity: .detached),
      Row(name: "experiments", activity: detachProblem(.nothingAttached)),
      Row(name: "scratch", activity: detachProblem(.notSent)),
      Row(name: "release-check", activity: detachProblem(.notClosed, failure: .sshFailed)),
      Row(
        name: "docs-site",
        activity: detachProblem(
          .checkFailed, failure: .notWritable, check: .clientCheckFailed(.notWritable))),
    ])

  /// The activity after a plain "Detach other clients…" in Terminal that ended `outcome` with
  /// `detached` confirmed.
  static func otherClients(
    _ outcome: DetachOtherClientsResult.Outcome, detached: Int
  ) -> SessionActivity {
    AppModel.activity(
      after: DetachOtherClientsResult(key: sampleKey, outcome: outcome, detachedClients: detached),
      wording: Sessions.terminalWording)!
  }

  /// "Detach other clients…" in Terminal stopped partway: after two (the window changed), none
  /// (known), some that may have been, after one (the listing failed), not held any more.
  public static let detachOtherClients = cards(
    .plain(Sessions.terminal), id: "terminals-detach-other-clients",
    title: "Terminal: Detach other clients stopped", first: 480, clients: 3,
    [
      Row(name: "api-server", activity: otherClients(.identityChanged, detached: 2)),
      Row(name: "build-farm", activity: otherClients(.identityChanged, detached: 0)),
      Row(
        name: "experiments",
        activity: otherClients(.checkFailed(.plainDetach(.sshFailed)), detached: 1)),
      Row(
        name: "scratch",
        activity: otherClients(.checkFailed(.plainClientListing(.timedOut)), detached: 1)),
      Row(name: "release-check", activity: otherClients(.notAttachedHere, detached: 0)),
    ])

  /// The Move here confirmation for Ghostty.
  public static let moveHere: PreviewFixture = Sessions.choosing(
    .plain(Sessions.ghostty),
    {
      var fixture = AttachFixtures.moveHere
      fixture.id = "terminals-move-here"
      fixture.title = "Ghostty: Move here"
      return fixture
    }())

  /// The Detach other clients confirmation for Terminal.
  public static let detachOtherClientsPanel: PreviewFixture = Sessions.choosing(
    .plain(Sessions.terminal),
    {
      var fixture = AttachFixtures.detachOtherClients
      fixture.id = "terminals-detach-other-clients-panel"
      fixture.title = "Terminal: Detach other clients"
      return fixture
    }())

  // MARK: - The unavailable choice and notes

  /// Each unavailable reason's line, with "Open Settings": not installed, too old, version
  /// unreadable, an id no definition has.
  public static let unavailable: [PreviewFixture] = {
    let reasons: [TerminalChoiceUnavailable] = [
      Sessions.ghosttyMissing,
      TerminalChoiceUnavailable(
        terminalID: "ghostty", reason: .versionTooOld(minimum: TerminalVersion("1.3")!)),
      Sessions.terminalVersionUnknown,
      TerminalChoiceUnavailable(terminalID: "warp", reason: .unknownID),
    ]
    return cards(
      .unavailable(Sessions.ghosttyMissing), id: "terminals-unavailable",
      title: "An unavailable choice", first: 490,
      failureRows(
        reasons.map {
          .terminalUnavailable(
            $0, wording: TerminalWording(.unavailable($0), catalog: Sessions.catalog))
        }))
  }()

  /// A window or an app not brought forward: an Open's problems, and the notes of a focus that
  /// did nothing.
  public static let notBroughtForward: [PreviewFixture] = {
    let wording = Sessions.terminalWording
    /// The note of a window focus that failed with `error`.
    func note(_ error: PlainTerminalWindowError) -> String? {
      SessionProblem.focusNote(.plainWindowFailed(error), wording: wording)
    }
    return cards(
      .plain(Sessions.terminal), id: "terminals-not-brought-forward",
      title: "Terminal: not brought forward", first: 500,
      [
        Row(
          name: "api-server",
          activity: .failed(
            .windowNotBroughtForward(
              .plainWindowFailed(.permissionDenied(appName: "Terminal")), wording: wording))),
        Row(
          name: "build-farm",
          activity: .failed(.appNotBroughtForward(.refused, app: Sessions.ghosttyWording))),
        Row(
          name: "experiments", activity: .confirmedInTerminal(wording),
          note: note(.windowLacksFocusValue(appName: "Terminal", .tty))),
        Row(
          name: "scratch", activity: .focusedWindow(wording),
          note: note(.appNotRunning(appName: "Terminal"))),
      ])
  }()

  /// Every terminal fixture of the attach gallery, after `AttachFixtures.all`.
  public static let all =
    windowFailures + ghosttyWindowFailures + launchFailures + refusals + earlierLaunch + detach
    + detachOtherClients + [moveHere, detachOtherClientsPanel] + unavailable + notBroughtForward

  // MARK: - Context menus

  /// A session menu card: the terminal's fixture (whose model words the menu) and its rows.
  public struct MenuCard: Sendable, Hashable, Identifiable {
    /// The card's title.
    public let title: String
    /// The fixture whose model the menu talks to.
    public let fixture: PreviewFixture
    /// The rows whose menus the card draws.
    public let rows: [SessionRow]

    /// `Identifiable` conformance: the fixture's id.
    public var id: String { fixture.id }
  }

  /// Terminal chosen: a session with its Terminal window and a client in iTerm2 here ("Open in
  /// Terminal", "Show window", "Show in iTerm2", "Detach from this Mac"), and one muxFinder
  /// attached in iTerm2 before Terminal was chosen ("Detach (opened in iTerm2)").
  public static let terminalMenu: MenuCard = {
    let local = [
      Sessions.open("notes", id: 390, in: .iTerm2(), clients: 2),
      PreviewFixtures.session(
        "index-rebuild", id: 391, on: PreviewFixtures.neptuno, windows: 3, clients: 1),
    ]
    let state = Sessions.hosts(saturno: [], neptuno: local)
    let fixture = Sessions.choosing(
      .plain(Sessions.terminal),
      PreviewFixture(
        id: "terminals-menu-terminal", title: "Terminal's menu", state: state,
        attachedHere: [
          local[1].key: AttachmentRecord(connectionID: "fixture", gatewaySessionID: "f")
        ]),
      records: ["terminal": [local[0].key: .plainWindow(Sessions.terminalWindow)]])
    let rows = PopoverContent(
      state: state, hostList: .saved, query: "", activities: [:], selection: nil,
      now: PreviewFixtures.now, windowsHere: [local[0].key], catalog: Sessions.catalog,
      otherTerminalDetaches: [
        local[1].key: [OtherTerminalDetach(terminalID: TerminalChoice.iTerm2ID, wording: .iTerm2)]
      ],
      wording: Sessions.terminalWording
    ).sections.flatMap(\.rows)
    return MenuCard(title: "Terminal: session context menu", fixture: fixture, rows: rows)
  }()

  /// Ghostty chosen: a session open in Terminal here, opened by muxFinder in Terminal before
  /// Ghostty was chosen ("Show in Terminal", "Detach (opened in Terminal)").
  public static let ghosttyMenu: MenuCard = {
    let local = [Sessions.open("notes", id: 392, in: Sessions.terminalApp)]
    let state = Sessions.hosts(saturno: [], neptuno: local)
    let fixture = Sessions.choosing(
      .plain(Sessions.ghostty),
      PreviewFixture(id: "terminals-menu-ghostty", title: "Ghostty's menu", state: state),
      records: ["terminal": [local[0].key: .plainWindow(Sessions.terminalWindow)]])
    let rows = PopoverContent(
      state: state, hostList: .saved, query: "", activities: [:], selection: nil,
      now: PreviewFixtures.now, catalog: Sessions.catalog,
      otherTerminalDetaches: [
        local[0].key: [
          OtherTerminalDetach(terminalID: "terminal", wording: Sessions.terminalWording)
        ]
      ],
      wording: Sessions.ghosttyWording
    ).sections.flatMap(\.rows)
    return MenuCard(title: "Ghostty: session context menu", fixture: fixture, rows: rows)
  }()

  /// The terminal menu cards, after iTerm2's (`AttachFixtures.menuRows`).
  public static let menus = [terminalMenu, ghosttyMenu]
} // End of enum TerminalAttachFixtures
