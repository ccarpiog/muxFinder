import Foundation
import Testing

@testable import MuxFinderCore
@testable import MuxFinderUI

/// The popover's, the switcher's and the session states' strings per terminal (PLAN.md D38
/// *The UI (I-12d2)*; requirements 9 and 12): with iTerm2's wording every string is the old
/// literal, with Terminal's and Ghostty's every action and state names that terminal and its
/// place.
@Suite("Terminal session wording")
struct TerminalSessionWordingTests {
  /// Terminal's wording.
  static let terminal = TerminalSessionFixtures.terminalWording
  /// Ghostty's wording.
  static let ghostty = TerminalSessionFixtures.ghosttyWording
  /// A user definition's wording.
  static let user = TerminalWording(name: "WezTerm", kind: .other)

  /// Requirement 12: iTerm2's strings are byte for byte the literals they were before other
  /// terminals, through every new entry point.
  @Test func iTerm2StringsAreUnchanged() {
    let wording = TerminalWording.iTerm2
    #expect(wording.openTitle == "Open in iTerm2")
    #expect(wording.openHint == "Opens the session in iTerm2.")
    #expect(wording.showTitle == "Show tab")
    #expect(
      wording.detachHelp
        == "Detaches this Mac's iTerm2 from the session. The session keeps running.")
    #expect(
      wording.detachOtherClientsHelp
        == "Detaches the session's other clients, such as iTerm2 on your other Macs, and keeps "
        + "this Mac's. The session keeps running.")
    #expect(wording.quitHelp == "Quit muxFinder. Your tmux sessions and iTerm2 tabs keep running.")
    #expect(wording.waitingText == "Waiting for iTerm2…")
    #expect(wording.stillConnectingText == "Still connecting — check the iTerm2 tab")
    #expect(wording.confirmedText == "Confirmed — open in iTerm2 on this Mac")
    #expect(wording.focusedText == "Already open here — brought its tab forward")
    #expect(wording.creatingText == "Creating the session and opening it in iTerm2…")
    #expect(
      wording.signInProblem
        == "SSH could not sign in without asking. Set up SSH for this host in iTerm2 first.")
    #expect(
      wording.hostKeyUnknownProblem
        == "SSH does not know this host's key yet. Connect once in iTerm2 to check it.")
    #expect(
      wording.earlierLaunchPending
        == "An earlier launch of this session may still attach it in iTerm2, so muxFinder did "
        + "not start another. Finish or close that launch tab, then try again.")
    #expect(wording.launchStoppedPrefix == "The launch tab in iTerm2 stopped: ")
    #expect(
      wording.moveHereExplanation(hostName: "Saturno")
        == "muxFinder will open this session from Saturno in iTerm2 on this Mac and disconnect "
        + "every other client attached to it, including iTerm2 on your other Macs. Nothing is "
        + "closed: the session keeps running, and the other Macs can attach again later.")
    #expect(
      wording.detachOtherClientsExplanation(hostName: "Saturno")
        == "muxFinder will have tmux detach every other client of this session on Saturno and "
        + "keep this Mac's attachment. They may be iTerm2 on your other Macs. Nothing is closed: "
        + "the session keeps running, and they can attach again later.")
    #expect(wording.otherClientsHereText(2) == ", including 2 in this Mac's iTerm2")
  } // End of func iTerm2StringsAreUnchanged()

  /// The old entry points keep giving iTerm2's lines: the activities' texts, the panels', the
  /// New session state, the host problems, and every problem mapping's default equals the
  /// mapping with iTerm2's wording.
  @Test func oldEntryPointsAreITerm2s() {
    #expect(SessionActivity.waitingForITerm2.text == "Waiting for iTerm2…")
    #expect(
      SessionActivity.stillConnecting(launchTabID: "t").text
        == "Still connecting — check the iTerm2 tab")
    #expect(SessionActivity.confirmed.text == "Confirmed — open in iTerm2 on this Mac")
    #expect(SessionActivity.focused.text == "Already open here — brought its tab forward")
    let key = PreviewFixtures.session("s", id: 1, on: PreviewFixtures.saturno, windows: 1).key
    let target = AttachTarget(
      host: PreviewFixtures.saturno,
      session: PreviewFixtures.session("s", id: 1, on: PreviewFixtures.saturno, windows: 1)
        .discovered)
    let move = MoveHereRequest(target: target)
    #expect(move.explanation == move.explanation(in: .iTerm2))
    let others = DetachOtherClientsRequest(target: target, otherClients: 2, otherClientsHere: 1)
    #expect(others.explanation == others.explanation(in: .iTerm2))
    #expect(
      others.clientsText
        == "2 other clients were attached when muxFinder last looked, including 1 in this Mac's "
        + "iTerm2.")
    var draft = NewSessionDraft()
    draft.state = .creating
    #expect(draft.stateMessage == "Creating the session and opening it in iTerm2…")
    for status: HostStatus in [.authFailed, .hostKeyProblem(.unknown), .tmuxNotFound] {
      #expect(
        HostProblemText.explanation(for: status)
          == HostProblemText.explanation(for: status, wording: .iTerm2))
    }
    for failure in FailureMessageTests.attachSamples {
      #expect(
        SessionProblem.attach(failure, launchTab: "t")
          == SessionProblem.attach(failure, launchTab: "t", wording: .iTerm2))
    }
    for outcome in SessionDetachResult.Outcome.allCases {
      let result = SessionDetachResult(
        key: key, outcome: outcome, checkFailure: .attachmentCheckFailed(.timedOut))
      #expect(SessionProblem.detach(result) == SessionProblem.detach(result, wording: .iTerm2))
    }
    for outcome in DetachOtherClientsUITests.outcomes {
      let result = DetachOtherClientsResult(key: key, outcome: outcome)
      #expect(
        SessionProblem.detachOtherClients(result)
          == SessionProblem.detachOtherClients(result, wording: .iTerm2))
      #expect(
        AppModel.activity(after: result) == AppModel.activity(after: result, wording: .iTerm2))
    }
    for result: TerminalFocusResult in [
      .launchTab(.notOpenedHere), .launchTab(.failed(.timedOut)), .handleOfAnotherTerminal,
      .appActivation(.refused), .plainWindowFocused,
    ] {
      #expect(
        SessionProblem.focusNote(result) == SessionProblem.focusNote(result, wording: .iTerm2))
    }
    for state: AttachState in [
      .requested, .launched(sessionID: "t"), .stillWaiting(sessionID: "t"),
      .confirmed(connectionID: "c"), .focused(connectionID: "c"),
    ] {
      #expect(SessionActivity(state) == SessionActivity(state, wording: Self.terminal))
    }
  } // End of func oldEntryPointsAreITerm2s()

  /// Every action and state names a plain terminal and its place, and none of them speaks of
  /// iTerm2 (the name refusal's "choose iTerm2 in Settings" aside).
  @Test(arguments: [terminal, ghostty, user])
  func stringsPerTerminal(_ wording: TerminalWording) {
    let name = wording.name
    #expect(wording.openTitle == "Open in \(name)")
    #expect(wording.openHint == "Opens the session in \(name).")
    #expect(wording.showTitle == "Show window")
    #expect(wording.waitingText == "Waiting for \(name)…")
    #expect(wording.stillConnectingText == "Still connecting — check the \(name) window")
    #expect(wording.confirmedText == "Confirmed — open in \(name) on this Mac")
    #expect(wording.focusedText == "Already open here — brought its \(name) window forward")
    #expect(wording.openOnThisMacText == "Open in \(name) on this Mac")
    #expect(wording.showInTitle == "Show in \(name)")
    #expect(wording.detachOpenedInTitle == "Detach (opened in \(name))")
    #expect(
      wording.quitHelp == "Quit muxFinder. Your tmux sessions and \(name) windows keep running.")
    let lines = [
      wording.openTitle, wording.openHint, wording.detachHelp,
      wording.detachOtherClientsHelp, wording.quitHelp, wording.waitingText,
      wording.stillConnectingText, wording.confirmedText, wording.focusedText,
      wording.creatingText, wording.openOnThisMacText, wording.showInTitle,
      wording.focusedAppText, wording.detachOpenedInTitle, wording.detachOpenedInHelp,
      wording.moveHereExplanation(hostName: "Saturno"),
      wording.detachOtherClientsExplanation(hostName: "Saturno"), wording.signInProblem,
      wording.hostKeyUnknownProblem, wording.earlierLaunchPending, wording.launchStoppedPrefix,
      wording.windowTimedOut, wording.windowWaitLimitReached, wording.windowIdentityUnconfirmed,
      wording.windowIdentityMismatch, wording.windowCannotConfirm, wording.alreadyOpenInWindow,
      wording.unavailableNotInstalled, wording.unavailableTooOld(minimum: "1.3"),
      wording.unavailableVersionUnknown(minimum: "1.3"), wording.detachNothingHere,
      wording.detachNotSent, wording.othersNotHere,
    ]
    for line in lines {
      #expect(line.contains(name), "\(line)")
      #expect(!line.contains("iTerm2"), "\(line)")
      #expect(!line.contains(" tab"), "\(line)")
    }
    #expect(Set(lines).count == lines.count)
    #expect(wording.unsupportedSessionName.hasPrefix("\(name) windows can't attach a session"))
    let detached = SessionActivity.detached.text
    #expect(detached == "Detached from this Mac — the session keeps running")
  } // End of func stringsPerTerminal(_:)

  /// The plain backend's states map to the plain activities, worded for the window's terminal
  /// (a launch) or the action's (a result); their flags, and the window "Show window" brings
  /// forward.
  @Test func plainStatesMapToPlainActivities() throws {
    let window = TerminalSessionFixtures.terminalWindow
    let terminal = Self.terminal
    #expect(SessionActivity(.plainLaunched(window: window)) == .waitingForTerminal(terminal))
    #expect(
      SessionActivity(.plainStillWaiting(window: window))
        == .stillConnectingInWindow(window, terminal))
    let client = TerminalAttachFixtures.client
    #expect(
      SessionActivity(.plainConfirmed(client: client), wording: Self.ghostty)
        == .confirmedInTerminal(Self.ghostty))
    #expect(
      SessionActivity(.plainFocused(client: client), wording: Self.ghostty)
        == .focusedWindow(Self.ghostty))
    #expect(
      SessionActivity(.appFocused(app: .iTerm2()), wording: Self.ghostty) == .focusedApp(.iTerm2))
    let states: [SessionActivity] = [
      .waitingForTerminal(terminal), .stillConnectingInWindow(window, terminal),
      .confirmedInTerminal(terminal), .focusedWindow(terminal), .focusedApp(Self.ghostty),
    ]
    #expect(states.map(\.isInProgress) == [true, true, false, false, false])
    #expect(states.map(\.isDone) == [false, false, true, true, true])
    #expect(states.map(\.isAttached) == [false, false, true, true, true])
    #expect(
      states.map(\.text) == [
        "Waiting for Terminal…", "Still connecting — check the Terminal window",
        "Confirmed — open in Terminal on this Mac",
        "Already open here — brought its Terminal window forward",
        "Already open in Ghostty on this Mac — brought it forward",
      ])
    #expect(states[1].launchWindow == window && states[1].launchTabID == nil)
    #expect(SessionActivity.stillConnecting(launchTabID: "t").launchWindow == nil)
    let failed = SessionActivity.failed(
      .attach(.timedOut, wording: terminal, window: window))
    #expect(failed.launchWindow == window)
    #expect(SessionActivity.confirmed.isAttached && SessionActivity.focused.isAttached)
    #expect(![SessionActivity.detached, .opening, .noOtherClientsLeft].contains { $0.isAttached })
    #expect(SessionProblem.Recovery.showWindow(window).title == "Show window")
    #expect(SessionProblem.Recovery.openAutomationSettings.title == "Open System Settings…")
  } // End of func plainStatesMapToPlainActivities()

  /// A session open in an app on this Mac is named from the loaded definitions: iTerm2 by its
  /// constant, Terminal and Ghostty by their definitions, an app no definition names
  /// neutrally; the row keeps one entry per app.
  @Test func appsAreNamedFromTheDefinitions() {
    let catalog = TerminalSessionFixtures.catalog
    #expect(TerminalWording(app: .iTerm2(), catalog: catalog) == .iTerm2)
    #expect(
      TerminalWording(app: TerminalSessionFixtures.terminalApp, catalog: catalog) == Self.terminal)
    #expect(
      TerminalWording(app: TerminalSessionFixtures.ghosttyApp, catalog: catalog) == Self.ghostty)
    #expect(
      TerminalWording(app: TerminalSessionFixtures.ghosttyApp, catalog: nil).name
        == TerminalWording.otherAppName)
    let attachments = [
      LocalAttachment(
        app: TerminalSessionFixtures.terminalApp, clientPID: 1, terminalPath: "/dev/ttys001",
        isControlMode: false),
      LocalAttachment(
        app: LocalTerminalApp(bundleIdentifier: "com.APPLE.terminal", definitionIDs: ["terminal"])!,
        clientPID: 2, terminalPath: "/dev/ttys002", isControlMode: false),
      LocalAttachment(
        app: .iTerm2(), clientPID: 3, terminalPath: "/dev/ttys003", isControlMode: true),
    ]
    let apps = SessionRow.openInApps(attachments, catalog: catalog)
    #expect(
      apps.map(\.badgeText) == ["Open in Terminal on this Mac", "Open in iTerm2 on this Mac"])
    #expect(apps.map(\.showTitle) == ["Show in Terminal", "Show in iTerm2"])
  } // End of func appsAreNamedFromTheDefinitions()
} // End of struct TerminalSessionWordingTests

/// Every `PlainTerminalWindowError` and every `AttachFailure` a plain terminal can end in has
/// its own line and recoveries (PLAN.md D38 *The UI (I-12d2)*), enforced by exhaustive switches
/// over the cases; none falls to the generic line (its core message with "Try again").
@Suite("Terminal error mapping")
struct TerminalErrorMappingTests {
  /// One sample of every window error, for Terminal; `caseIndex(_:)` makes the compiler insist
  /// on a sample for a new case.
  static let windowSamples: [PlainTerminalWindowError] = [
    .appNotInstalled(appName: "Terminal"),
    .appTooOld(appName: "Terminal", installed: "1.9", minimum: "2.0"),
    .appVersionUnknown(appName: "Terminal", minimum: "2.0"), .permissionDenied(appName: "Terminal"),
    .appNotRunning(appName: "Terminal"), .activationFailed(appName: "Terminal"),
    .launchCommandRefused(.helperPathUnsafeForWords),
    .scriptFailed(appName: "Terminal", .callFailed(handler: .open, errorNumber: -2700)),
    .scriptMissing(appName: "Terminal"), .malformedReply(appName: "Terminal", handler: .open),
    .spawnFailed(appName: "Terminal", .spawnFailed(errno: 2)), .windowOfAnotherTerminal,
    .definitionChanged(appName: "Terminal"), .notOpenedHere,
    .windowLacksFocusValue(appName: "Terminal", .tty), .windowHasNoID(appName: "Terminal"),
    .windowBusy(appName: "Terminal"), .windowGone(appName: "Terminal"),
    .unattendedRunRefused(appName: "Terminal", .notRunning),
  ]

  /// The script failure variants, for Terminal.
  static let scriptSamples: [AppleScriptRunnerError] = [
    .compileFailed(errorNumber: -2740), .callFailed(handler: .open, errorNumber: -600),
    .callFailed(handler: .open, errorNumber: -1708), .callFailed(handler: .focus, errorNumber: -1),
    .callFailed(handler: .close, errorNumber: -1), .wrongArgumentCount(handler: .open),
  ]

  /// The case's position, exhaustively.
  static func caseIndex(_ error: PlainTerminalWindowError) -> Int {
    switch error {
    case .appNotInstalled: return 0
    case .appTooOld: return 1
    case .appVersionUnknown: return 2
    case .permissionDenied: return 3
    case .appNotRunning: return 4
    case .activationFailed: return 5
    case .launchCommandRefused: return 6
    case .scriptFailed: return 7
    case .scriptMissing: return 8
    case .malformedReply: return 9
    case .spawnFailed: return 10
    case .windowOfAnotherTerminal: return 11
    case .definitionChanged: return 12
    case .notOpenedHere: return 13
    case .windowLacksFocusValue: return 14
    case .windowHasNoID: return 15
    case .windowBusy: return 16
    case .windowGone: return 17
    case .unattendedRunRefused: return 18
    }
  } // End of static func caseIndex(_:)

  /// The problem of an Open whose window ended `error`, in Terminal.
  static func problem(_ error: PlainTerminalWindowError) -> SessionProblem {
    .attach(.terminalWindow(error), wording: TerminalSessionWordingTests.terminal)
  }

  /// Each window error's line: its own (pairwise distinct, never the generic line), a sentence
  /// naming the app where it has one; the same whatever wording calls it but Ghostty's
  /// AppleScript case (so an iTerm2 default call matches the model's); the recoveries the calls
  /// list.
  @Test func everyWindowErrorHasItsOwnLine() {
    #expect(Set(Self.windowSamples.map(Self.caseIndex)) == Set(0...18))
    let problems =
      Self.windowSamples.map(Self.problem)
      + Self.scriptSamples.map { Self.problem(.scriptFailed(appName: "Terminal", $0)) }
    let messages = problems.map(\.message)
    #expect(Set(messages).count == messages.count)
    for (error, problem) in zip(Self.windowSamples, problems) {
      let generic = SessionProblem(
        message: AttachFailure.terminalWindow(error).message, recoveries: [.retry])
      #expect(problem != generic, "\(error.kind)")
      #expect(problem.message.hasSuffix("."), "\(error.kind)")
      #expect(problem == SessionProblem.attach(.terminalWindow(error)), "\(error.kind)")
      #expect(!problem.message.contains("iTerm2"), "\(error.kind)")
      switch error {
      case .windowOfAnotherTerminal, .notOpenedHere, .launchCommandRefused:
        break
      default:
        #expect(problem.message.contains("Terminal"), "\(error.kind)")
      }
    } // End of loop over the window errors
    #expect(problems[0].recoveries == [.openSettings])
    #expect(problems[3].recoveries == [.openAutomationSettings, .retry])
    #expect(problems[3].message.hasPrefix("muxFinder isn't allowed to control Terminal"))
    #expect(problems[4].message.hasPrefix("Terminal isn't running and couldn't be opened"))
    #expect(problems[6].recoveries.isEmpty, "moving muxFinder is the fix")
    #expect(problems.filter { $0.recoveries.isEmpty }.count == 1)
    #expect(
      problems[20].message.hasPrefix("Terminal isn't running and couldn't be opened (error -600)"))
    #expect(
      !problems[21].message.contains("AppleScript"), "-1708 is AppleScript off only for Ghostty")
  } // End of func everyWindowErrorHasItsOwnLine()

  /// Ghostty's AppleScript turned off: its numbers on Ghostty's open, with where to turn it on.
  @Test func ghosttysAppleScriptTurnedOff() {
    for number in TerminalWording.appleScriptOffErrorNumbers {
      let problem = SessionProblem.attach(
        .terminalWindow(
          .scriptFailed(appName: "Ghostty", .callFailed(handler: .open, errorNumber: number))),
        wording: TerminalSessionWordingTests.ghostty)
      #expect(problem.message.hasPrefix("Ghostty's AppleScript is turned off (error \(number))"))
      #expect(problem.message.contains("macos-applescript = false"))
      #expect(problem.recoveries == [.retry])
    }
    let focus = SessionProblem.attach(
      .terminalWindow(
        .scriptFailed(appName: "Ghostty", .callFailed(handler: .focus, errorNumber: -1708))),
      wording: TerminalSessionWordingTests.ghostty)
    #expect(!focus.message.contains("AppleScript"))
  } // End of func ghosttysAppleScriptTurnedOff()

  /// How a plain terminal's line relates to iTerm2's, per failure.
  enum Category {
    /// Worded for the plain terminal.
    case plain
    /// The core's neutral sentence.
    case neutral
    /// iTerm2's own (its index or API): the plain backend never reports it.
    case iTerm2
  }

  /// Each failure's category, exhaustively.
  static func category(_ failure: AttachFailure) -> Category {
    switch failure {
    case .identityMismatch, .helperFailed, .timedOut, .waitLimitReached, .identityCheckFailed,
      .earlierLaunchPending, .terminalWindow, .cannotConfirmHere, .clientCheckFailed,
      .alreadyOpenInTerminal, .unsupportedSessionName:
      return .plain
    case .invalidDestination, .sessionGone, .sessionChanged, .tmuxMissing, .discoveryFailed,
      .launchStore, .helperEnded, .cancelled, .moveHereNotConfirmed:
      return .neutral
    case .iTerm2, .attachmentCheckFailed, .attachmentChanged, .alreadyAttachedHere,
      .possiblyAttachedHere:
      return .iTerm2
    }
  } // End of static func category(_:)

  /// Every `AttachFailure` in Terminal: the plain ones name Terminal (and its window), differ
  /// from iTerm2's line and offer "Show window" where the window explains more; the neutral
  /// ones keep the core's sentence; iTerm2's own keep iTerm2's line.
  @Test func everyAttachFailureInAPlainTerminal() throws {
    let window = TerminalSessionFixtures.terminalWindow
    let samples =
      FailureMessageTests.attachSamples + [
        .terminalWindow(.permissionDenied(appName: "Terminal")), .cannotConfirmHere,
        .clientCheckFailed(.sshFailed), .alreadyOpenInTerminal(window: window),
        .unsupportedSessionName,
      ]
    #expect(Set(samples.map(FailureMessageTests.caseIndex)) == Set(0...24))
    var plainMessages: [String] = []
    for failure in samples {
      let problem = SessionProblem.attach(
        failure, wording: TerminalSessionWordingTests.terminal, window: window)
      #expect(!problem.recoveries.isEmpty, "\(failure.kind)")
      switch Self.category(failure) {
      case .plain:
        #expect(problem.message.contains("Terminal"), "\(failure.kind)")
        if case .terminalWindow = failure {
          // Worded by its own app name whatever the wording (`everyWindowErrorHasItsOwnLine`).
        } else {
          #expect(problem != SessionProblem.attach(failure), "\(failure.kind)")
        }
        plainMessages.append(problem.message)
      case .neutral:
        #expect(problem.message == failure.message, "\(failure.kind)")
      case .iTerm2:
        #expect(problem == SessionProblem.attach(failure), "\(failure.kind)")
      }
    } // End of loop over the failures
    #expect(Set(plainMessages).count == plainMessages.count)
    for failure: AttachFailure in [
      .timedOut, .helperFailed(.sshFailed(.authFailed)), .waitLimitReached, .cannotConfirmHere,
    ] {
      let problem = SessionProblem.attach(
        failure, wording: TerminalSessionWordingTests.terminal, window: window)
      #expect(problem.recoveries.first == .showWindow(window), "\(failure.kind)")
      let without = SessionProblem.attach(failure, wording: TerminalSessionWordingTests.terminal)
      #expect(!without.recoveries.contains(.showWindow(window)), "\(failure.kind)")
    }
    let helper = SessionProblem.attach(
      .helperFailed(.sshFailed(.authFailed)), wording: TerminalSessionWordingTests.terminal)
    #expect(helper.message.hasPrefix("The Terminal window stopped: "))
    #expect(!helper.message.contains("above"))
    let refusal = SessionProblem.attach(
      .unsupportedSessionName, wording: TerminalSessionWordingTests.terminal)
    #expect(refusal.message.hasPrefix("Terminal windows can't attach a session whose name has"))
    #expect(refusal.recoveries == [.refresh])
    let moved = SessionProblem.attach(
      .alreadyOpenInTerminal(window: TerminalSessionFixtures.ghosttyWindow),
      wording: TerminalSessionWordingTests.terminal)
    #expect(moved.message.hasPrefix("This session is already open in a Ghostty window"))
  } // End of func everyAttachFailureInAPlainTerminal()

  /// Each window error at a focus has its own note, naming the app where it has one.
  @Test func everyWindowErrorHasAFocusNote() {
    for error in Self.windowSamples {
      let note = SessionProblem.focusNote(
        .plainWindowFailed(error), wording: TerminalSessionWordingTests.terminal)
      #expect(note?.hasSuffix(".") == true, "\(error.kind)")
      #expect(note == SessionProblem.windowFocusNote(error, kind: .terminalApp))
      #expect(note == SessionProblem.focusNote(.plainWindowFailed(error)))
    }
    #expect(
      SessionProblem.focusNote(.plainWindowFailed(.permissionDenied(appName: "Terminal")))
        == "muxFinder isn't allowed to control Terminal, so it brought nothing forward. Allow it "
        + "in System Settings › Privacy & Security › Automation.")
  } // End of func everyWindowErrorHasAFocusNote()

  /// The unavailable choice names the chosen terminal: not installed, too old, of an unreadable
  /// version; an id no definition has keeps the core's sentence (it quotes the id), and so does
  /// a call without the wording. "Open Settings" every time.
  @Test func theUnavailableChoiceNamesTheTerminal() {
    let ghostty = TerminalSessionWordingTests.ghostty
    let missing = SessionProblem.terminalUnavailable(
      TerminalSessionFixtures.ghosttyMissing, wording: ghostty)
    #expect(missing.message.hasPrefix("The chosen terminal, Ghostty, isn't installed."))
    let old = SessionProblem.terminalUnavailable(
      TerminalChoiceUnavailable(
        terminalID: "ghostty", reason: .versionTooOld(minimum: TerminalVersion("1.3")!)),
      wording: ghostty)
    #expect(old.message.hasPrefix("The chosen terminal, Ghostty, is older than 1.3."))
    let unknown = SessionProblem.terminalUnavailable(
      TerminalSessionFixtures.terminalVersionUnknown,
      wording: TerminalSessionWordingTests.terminal)
    #expect(unknown.message.contains("the chosen terminal, Terminal"))
    let warp = TerminalChoiceUnavailable(terminalID: "warp", reason: .unknownID)
    #expect(
      SessionProblem.terminalUnavailable(warp, wording: TerminalWording(name: "x", kind: .other))
        .message == warp.message)
    #expect(
      SessionProblem.terminalUnavailable(TerminalSessionFixtures.ghosttyMissing).message
        == TerminalSessionFixtures.ghosttyMissing.message)
    let all = [missing, old, unknown]
    #expect(all.allSatisfy { $0.recoveries == [.openSettings] })
    #expect(Set(all.map(\.message)).count == 3)
  } // End of func theUnavailableChoiceNamesTheTerminal()
} // End of struct TerminalErrorMappingTests

/// A plain "Detach from this Mac" and "Detach other clients…" in the terminal that ran them
/// (PLAN.md D37, D38 *The UI (I-12d2)*; I-12c1's open risk): a run stopped partway says how
/// many it detached when that is known and that some may have been when it is not, never
/// "none detached" when that is unproven.
@Suite("Plain detach wording")
struct PlainDetachWordingTests {
  /// The session of the samples.
  static let key = PreviewFixtures.session("s", id: 1, on: PreviewFixtures.saturno, windows: 1).key

  /// The problem a plain run that ended `outcome` with `detached` confirmed shows.
  static func problem(
    _ outcome: DetachOtherClientsResult.Outcome, detached: Int
  ) -> SessionProblem? {
    SessionProblem.detachOtherClients(
      DetachOtherClientsResult(key: key, outcome: outcome, detachedClients: detached),
      wording: TerminalSessionWordingTests.terminal)
  }

  /// "Stopped after detaching N" when the count is known; "detached no other client" only when
  /// none was; "Some may have been detached" when a failed detach may have gone through.
  @Test func aRunStoppedPartwaySaysWhatIsKnown() throws {
    let after2 = try #require(Self.problem(.identityChanged, detached: 2))
    #expect(
      after2.message.hasPrefix(
        "Stopped after detaching 2 other clients: this Mac's Terminal window"))
    #expect(after2.recoveries == [.refresh])
    let none = try #require(Self.problem(.identityChanged, detached: 0))
    #expect(none.message.hasPrefix("muxFinder detached no other client: this Mac's Terminal"))
    let maybe = try #require(Self.problem(.checkFailed(.plainDetach(.sshFailed)), detached: 1))
    #expect(
      maybe.message.hasPrefix(
        "Stopped detaching the session's other clients. Some may have been detached:"))
    #expect(maybe.message.contains("At least 1 other client was."))
    #expect(!maybe.message.contains("no other client"))
    let maybeNone = try #require(Self.problem(.checkFailed(.plainDetach(.timedOut)), detached: 0))
    #expect(maybeNone.message.contains("Some may have been detached"))
    #expect(!maybeNone.message.contains("At least"))
    let notRun = try #require(Self.problem(.checkFailed(.plainDetach(.notWritable)), detached: 3))
    #expect(
      notRun.message.hasPrefix(
        "Stopped after detaching 3 other clients: a detach could not be sent."))
    let listing = try #require(
      Self.problem(.checkFailed(.plainClientListing(.timedOut)), detached: 1))
    #expect(
      listing.message.hasPrefix("Stopped after detaching 1 other client: muxFinder could not read"))
    #expect(listing.recoveries == [.retry, .refresh])
    let gone = try #require(Self.problem(.notAttachedHere, detached: 0))
    #expect(gone.message.hasPrefix("muxFinder's Terminal window no longer holds this session"))
    #expect(Self.problem(.detached(count: 1), detached: 1) == nil)
    #expect(Self.problem(.nothingToDetach, detached: 0) == nil)
    #expect(Self.problem(.cancelled, detached: 2) == nil)
    let messages = [after2, none, maybe, maybeNone, notRun, listing, gone].map(\.message)
    #expect(Set(messages).count == messages.count)
    #expect(messages.allSatisfy { $0.hasSuffix("The session keeps running.") })
  } // End of func aRunStoppedPartwaySaysWhatIsKnown()

  /// Over every plain outcome and count, "detached no other client" appears only when the
  /// result proves nothing may have been sent (`mayHaveSent` false).
  @Test func noneDetachedOnlyWhenProven() {
    let outcomes: [DetachOtherClientsResult.Outcome] = [
      .identityChanged, .checkFailed(.plainClientListing(.sshFailed)),
      .checkFailed(.plainDetach(.sshFailed)),
      .checkFailed(.plainDetach(.couldNotRun(.spawnFailed(errno: 2)))),
      .checkFailed(.plainDetach(.notWritable)),
    ]
    for outcome in outcomes {
      for detached in 0...2 {
        let result = DetachOtherClientsResult(
          key: Self.key, outcome: outcome, detachedClients: detached)
        let message =
          SessionProblem.detachOtherClients(result, wording: TerminalSessionWordingTests.terminal)?
          .message ?? ""
        if message.contains("no other client") {
          #expect(!result.mayHaveSent, "\(outcome.kind) \(detached)")
        }
        if result.mayHaveSent { #expect(!message.contains("no other client")) }
      }
    } // End of loop over the outcomes
  } // End of func noneDetachedOnlyWhenProven()

  /// A plain Detach's problems name the terminal's window; a cancelled one keeps iTerm2's
  /// neutral sentence; a detached one shows none.
  @Test func plainDetachLines() {
    let terminal = TerminalSessionWordingTests.terminal
    /// The problem of a plain detach that ended `outcome`.
    func problem(
      _ outcome: SessionDetachResult.Outcome, failure: PlainTmuxCommandFailure? = nil,
      check: AttachFailure? = nil
    ) -> SessionProblem? {
      SessionProblem.detach(
        SessionDetachResult(
          key: Self.key, outcome: outcome, checkFailure: check,
          plainDetach: PlainDetachResult(client: TerminalAttachFixtures.client, failure: failure)),
        wording: terminal)
    }
    #expect(problem(.detached) == nil)
    let nothing = problem(.nothingAttached)
    #expect(nothing?.message.hasPrefix("muxFinder has no Terminal window of this session") == true)
    #expect(nothing?.recoveries == [.refresh])
    #expect(problem(.notSent)?.message.contains("tmux client of its Terminal window") == true)
    let unknown = problem(.notClosed, failure: .sshFailed)
    #expect(unknown?.message.contains("ssh could not reach the session's host.") == true)
    #expect(unknown?.recoveries == [.retry, .refresh])
    let prepared = problem(
      .checkFailed, failure: .notWritable, check: .clientCheckFailed(.notWritable))
    #expect(prepared?.message.hasPrefix("muxFinder could not prepare the detach") == true)
    #expect(
      problem(.cancelled)
        == SessionProblem.detach(SessionDetachResult(key: Self.key, outcome: .cancelled)))
  } // End of func plainDetachLines()
} // End of struct PlainDetachWordingTests
