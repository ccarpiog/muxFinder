import Foundation
import MuxFinderCore

/// The popover's and the switcher's session states per terminal (PLAN.md D38 *The UI
/// (I-12d2)*) for `--preview-gallery popover` and `switcher`: iTerm2, Terminal and Ghostty for
/// the row actions, pending, confirmed, focused, failed, a session open in another app on this
/// Mac, and an unavailable choice. The session actions' failures per terminal are
/// `TerminalAttachFixtures`. Synthetic data only: Terminal's and Ghostty's definitions decoded
/// in memory from copies of the built-ins' JSON (no file read, no script), invented session
/// names, `*.example` destinations, a fake socket path, fixed ids and window ids, made-up
/// terminal device names; building them runs nothing.
public enum TerminalSessionFixtures {
  /// Shorthand.
  typealias Fixtures = PreviewFixtures

  // MARK: - Terminals

  /// Terminal's definition, as the built-in `terminal.json` reads (no script loaded).
  public static let terminal = loaded(
    #"{"schemaVersion": 1, "id": "terminal", "displayName": "Terminal", "#
      + #""bundleIdentifier": "com.apple.Terminal", "minimumVersion": "2.0", "#
      + #""open": {"kind": "appleScript", "script": "terminal.applescript", "#
      + #""command": "shellText"}, "focus": {"kind": "tty"}}"#,
    fileName: "terminal.json")
  /// Ghostty's definition, as the built-in `ghostty.json` reads (no script loaded).
  public static let ghostty = loaded(
    #"{"schemaVersion": 1, "id": "ghostty", "displayName": "Ghostty", "#
      + #""bundleIdentifier": "com.mitchellh.ghostty", "minimumVersion": "1.3", "#
      + #""open": {"kind": "appleScript", "script": "ghostty.applescript", "#
      + #""command": "words"}, "focus": {"kind": "windowID"}}"#,
    fileName: "ghostty.json")
  /// The definitions the fixtures load, sorted by id as the loader sorts them.
  public static let catalog = TerminalDefinitionCatalog(
    definitions: [ghostty, terminal], problems: [])

  /// A built-in definition decoded from `json` (a constant that always decodes;
  /// `TerminalSessionFixtureTests` checks it).
  static func loaded(_ json: String, fileName: String) -> LoadedTerminalDefinition {
    let definition = try! TerminalDefinition.decode(Data(json.utf8))
    return LoadedTerminalDefinition(
      definition: definition, source: .builtIn, fileName: fileName, script: nil)
  }

  /// Terminal's wording.
  public static let terminalWording = TerminalWording(definition: terminal.definition)
  /// Ghostty's wording.
  public static let ghosttyWording = TerminalWording(definition: ghostty.definition)

  /// A Terminal window muxFinder opened (an invented id and terminal device).
  public static let terminalWindow = PlainTerminalWindow(
    openedBy: terminal, windowID: "4101", tty: "/dev/ttys041")
  /// A Ghostty window muxFinder opened (an invented stable id).
  public static let ghosttyWindow = PlainTerminalWindow(
    openedBy: ghostty, windowID: "fixture-ghostty-window", tty: nil)

  /// Terminal as process ancestry names it.
  public static let terminalApp = LocalTerminalApp(
    bundleIdentifier: "com.apple.Terminal", definitionIDs: ["terminal"])!
  /// Ghostty as process ancestry names it.
  public static let ghosttyApp = LocalTerminalApp(
    bundleIdentifier: "com.mitchellh.ghostty", definitionIDs: ["ghostty"])!

  /// Ghostty chosen but not installed.
  public static let ghosttyMissing = TerminalChoiceUnavailable(
    terminalID: "ghostty", reason: .notInstalled)
  /// Terminal chosen with a version that cannot be read.
  public static let terminalVersionUnknown = TerminalChoiceUnavailable(
    terminalID: "terminal", reason: .versionUnknown(minimum: TerminalVersion("2.0")!))
  /// iTerm2 chosen but not installed.
  public static let iTerm2Missing = TerminalChoiceUnavailable(
    terminalID: TerminalChoice.iTerm2ID, reason: .notInstalled)

  /// `fixture` with the terminal choice `choice` and the fixtures' definitions.
  static func choosing(
    _ choice: TerminalChoiceResolution,
    _ fixture: PreviewFixture,
    records: [String: [SessionKey: TerminalAttachmentHandle]] = [:]
  ) -> PreviewFixture {
    var chosen = fixture
    chosen.terminal = choice
    chosen.terminalDefinitions = catalog
    chosen.terminalAttachments = records
    return chosen
  } // End of static func choosing(_:_:records:)

  /// A session of This Mac a client of which runs in `app` (`clientPID` invented).
  static func open(
    _ name: String, id: Int, in app: LocalTerminalApp, clients: Int = 1
  ) -> HostSnapshot.Session {
    var session = Fixtures.session(
      name, id: id, on: Fixtures.neptuno, windows: 2, clients: clients)
    session.localAttachments = [
      LocalAttachment(
        app: app, clientPID: 9_400 + Int32(id), terminalPath: "/dev/ttys0\(id % 90 + 10)",
        isControlMode: false)
    ]
    return session
  } // End of static func open(_:id:in:clients:)

  /// Saturno's and This Mac's sessions, live.
  static func hosts(
    saturno: [HostSnapshot.Session], neptuno: [HostSnapshot.Session]
  ) -> RefreshState {
    AttachFixtures.hosts(saturno: saturno, neptuno: neptuno)
  }

  // MARK: - The popover

  /// iTerm2 chosen (requirement 12: its rows as before): a session open in Terminal on this
  /// Mac shows "Open in Terminal on this Mac" with "Show in Terminal" (Open still opens it in
  /// iTerm2), beside iTerm2's own waiting and confirmed rows, and an Open refused because a
  /// Terminal launch of the session may still attach it.
  public static let iTerm2Popover: PreviewFixture = {
    let local = [open("notes", id: 301, in: terminalApp), open("logs", id: 302, in: ghosttyApp)]
    let remote = AttachFixtures.saturnoSessions(
      ["build-farm", "experiments", "scratch"], first: 303)
    return choosing(
      .iTerm2,
      PreviewFixture(
        id: "terminals-iterm2", title: "iTerm2: sessions open in other apps",
        state: hosts(saturno: remote, neptuno: local), selection: local[0].key,
        activities: [
          remote[0].key: .waitingForITerm2, remote[1].key: .confirmed,
          remote[2].key: .failed(.attach(.earlierLaunchPending, wording: terminalWording)),
        ]))
  }()

  /// Terminal chosen, Saturno's sessions: Waiting for Terminal…, a remote window still
  /// connecting with "Show window", Confirmed, and a timed-out window with "Show window".
  public static let terminalPopover: PreviewFixture = {
    let remote = AttachFixtures.saturnoSessions(
      ["api-server", "build-farm", "experiments", "scratch"], first: 310)
    let activities: [SessionKey: SessionActivity] = [
      remote[0].key: .waitingForTerminal(terminalWording),
      remote[1].key: .stillConnectingInWindow(terminalWindow, terminalWording),
      remote[2].key: .confirmedInTerminal(terminalWording),
      remote[3].key: .failed(.attach(.timedOut, wording: terminalWording, window: terminalWindow)),
    ]
    return choosing(
      .plain(terminal),
      PreviewFixture(
        id: "terminals-terminal", title: "Terminal: opening and results",
        state: hosts(saturno: remote, neptuno: []), activities: activities))
  }()

  /// Terminal chosen, This Mac's sessions: one open in iTerm2 here (selected), one found open
  /// in Ghostty and brought forward, and Terminal's own window brought forward (its "Show
  /// window" and Detach in the menu).
  public static let terminalHerePopover: PreviewFixture = {
    let local = [
      open("notes", id: 314, in: .iTerm2()), open("logs", id: 315, in: ghosttyApp),
      Fixtures.session("index-rebuild", id: 316, on: Fixtures.neptuno, windows: 3, clients: 1),
    ]
    return choosing(
      .plain(terminal),
      PreviewFixture(
        id: "terminals-terminal-here", title: "Terminal: on this Mac",
        state: hosts(saturno: [], neptuno: local), selection: local[0].key,
        activities: [
          local[1].key: .focusedApp(ghosttyWording), local[2].key: .focusedWindow(terminalWording),
        ]),
      records: ["terminal": [local[2].key: .plainWindow(terminalWindow)]])
  }()

  /// Ghostty chosen, Saturno's sessions: Opening…, Waiting for Ghostty…, Confirmed.
  public static let ghosttyPopover: PreviewFixture = {
    let remote = AttachFixtures.saturnoSessions(
      ["api-server", "build-farm", "scratch"], first: 320)
    return choosing(
      .plain(ghostty),
      PreviewFixture(
        id: "terminals-ghostty", title: "Ghostty: opening and results",
        state: hosts(saturno: remote, neptuno: []),
        activities: [
          remote[0].key: .opening, remote[1].key: .waitingForTerminal(ghosttyWording),
          remote[2].key: .confirmedInTerminal(ghosttyWording),
        ]))
  }()

  /// Ghostty chosen, This Mac's sessions: one open in Terminal here, Ghostty's own window
  /// brought forward, and Ghostty's AppleScript turned off.
  public static let ghosttyHerePopover: PreviewFixture = {
    let local = [
      open("notes", id: 323, in: terminalApp),
      Fixtures.session("index-rebuild", id: 324, on: Fixtures.neptuno, windows: 3, clients: 1),
      Fixtures.session("journal", id: 325, on: Fixtures.neptuno, windows: 1),
    ]
    let activities: [SessionKey: SessionActivity] = [
      local[1].key: .focusedWindow(ghosttyWording),
      local[2].key: .failed(
        .attach(
          .terminalWindow(
            .scriptFailed(appName: "Ghostty", .callFailed(handler: .open, errorNumber: -1708))),
          wording: ghosttyWording)),
    ]
    return choosing(
      .plain(ghostty),
      PreviewFixture(
        id: "terminals-ghostty-here", title: "Ghostty: on this Mac",
        state: hosts(saturno: [], neptuno: local), activities: activities),
      records: ["ghostty": [local[1].key: .plainWindow(ghosttyWindow)]])
  }()

  /// An unavailable choice: every Open ends in its line with "Open Settings", nothing opened.
  static func unavailable(
    _ failure: TerminalChoiceUnavailable, id: String, title: String, first: Int
  ) -> PreviewFixture {
    let sessions = AttachFixtures.saturnoSessions(["api-server", "build-farm"], first: first)
    let wording = TerminalWording(.unavailable(failure), catalog: catalog)
    return choosing(
      .unavailable(failure),
      PreviewFixture(
        id: id, title: title, state: hosts(saturno: sessions, neptuno: []),
        activities: [
          sessions[0].key: .failed(.terminalUnavailable(failure, wording: wording))
        ]))
  } // End of static func unavailable(_:id:title:first:)

  /// iTerm2 chosen but not installed.
  public static let iTerm2Unavailable = unavailable(
    iTerm2Missing, id: "terminals-iterm2-unavailable", title: "iTerm2 chosen, not installed",
    first: 330)
  /// Terminal chosen, its version unreadable.
  public static let terminalUnavailable = unavailable(
    terminalVersionUnknown, id: "terminals-terminal-unavailable",
    title: "Terminal chosen, version unreadable", first: 333)
  /// Ghostty chosen but not installed.
  public static let ghosttyUnavailable = unavailable(
    ghosttyMissing, id: "terminals-ghostty-unavailable", title: "Ghostty chosen, not installed",
    first: 336)

  /// The popover gallery's terminal states, after `PreviewFixtures.all`.
  public static let popover = [
    iTerm2Popover, terminalPopover, terminalHerePopover, ghosttyPopover, ghosttyHerePopover,
    iTerm2Unavailable, terminalUnavailable, ghosttyUnavailable,
  ]

  // MARK: - The switcher

  /// This Mac's and Saturno's sessions for the switcher: one open in `app` here.
  static func switcherHosts(openIn app: LocalTerminalApp, first: Int) -> RefreshState {
    hosts(
      saturno: AttachFixtures.saturnoSessions(["build-farm", "experiments"], first: first + 1),
      neptuno: [open("notes", id: first, in: app)])
  }

  /// iTerm2 chosen, a session open in Terminal here: its badge and "Show in Terminal".
  public static let iTerm2Switcher = choosing(
    .iTerm2,
    PreviewFixture(
      id: "switcher-terminals-iterm2", title: "iTerm2: a session open in Terminal",
      state: switcherHosts(openIn: terminalApp, first: 340)))

  /// Terminal chosen: Waiting for Terminal… on the selected row, a session open in iTerm2.
  public static let terminalSwitcher: PreviewFixture = {
    let state = switcherHosts(openIn: .iTerm2(), first: 343)
    let key = state.hosts[0].sessions[1].key
    return choosing(
      .plain(terminal),
      PreviewFixture(
        id: "switcher-terminals-terminal", title: "Terminal: opening", state: state,
        activities: [key: .waitingForTerminal(terminalWording)],
        switcherSelection: .session(key)))
  }()

  /// Terminal chosen: an Open that muxFinder may not control Terminal for, with "Open System
  /// Settings…".
  public static let terminalSwitcherFailure: PreviewFixture = {
    let state = switcherHosts(openIn: ghosttyApp, first: 346)
    let key = state.hosts[0].sessions[0].key
    return choosing(
      .plain(terminal),
      PreviewFixture(
        id: "switcher-terminals-terminal-failure", title: "Terminal: not allowed", state: state,
        activities: [
          key: .failed(
            .attach(
              .terminalWindow(.permissionDenied(appName: "Terminal")), wording: terminalWording))
        ],
        switcherSelection: .session(key)))
  }()

  /// Ghostty chosen: Confirmed in Ghostty, a session open in Terminal here.
  public static let ghosttySwitcher: PreviewFixture = {
    let state = switcherHosts(openIn: terminalApp, first: 349)
    let key = state.hosts[0].sessions[1].key
    return choosing(
      .plain(ghostty),
      PreviewFixture(
        id: "switcher-terminals-ghostty", title: "Ghostty: confirmed", state: state,
        activities: [key: .confirmedInTerminal(ghosttyWording)], switcherSelection: .session(key)))
  }()

  /// Ghostty chosen but not installed: the Open's line with "Open Settings".
  public static let ghosttySwitcherUnavailable: PreviewFixture = {
    let state = switcherHosts(openIn: terminalApp, first: 352)
    let key = state.hosts[0].sessions[0].key
    return choosing(
      .unavailable(ghosttyMissing),
      PreviewFixture(
        id: "switcher-terminals-ghostty-unavailable", title: "Ghostty chosen, not installed",
        state: state,
        activities: [
          key: .failed(.terminalUnavailable(ghosttyMissing, wording: ghosttyWording))
        ],
        switcherSelection: .session(key)))
  }()

  /// The switcher gallery's terminal states, after `SwitcherFixtures.all`.
  public static let switcher = [
    iTerm2Switcher, terminalSwitcher, terminalSwitcherFailure, ghosttySwitcher,
    ghosttySwitcherUnavailable,
  ]
} // End of enum TerminalSessionFixtures
