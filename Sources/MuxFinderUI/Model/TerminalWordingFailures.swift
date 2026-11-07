import Foundation
import MuxFinderCore

/// What a failed session action says, per terminal (PLAN.md D38 *The UI (I-12d2)*): the plain
/// backend's attach, window, detach and "Detach other clients…" lines, built from the terminal's
/// name and place. `SessionProblem` picks the line and its recoveries with exhaustive switches;
/// the sentences live here, so `TerminalWording` stays the one source of terminal wording.
/// iTerm2's lines are `SessionProblem`'s and the core's, unchanged.
extension TerminalWording {
  /// The OSA error numbers Ghostty's open is taken to answer when its AppleScript is turned off
  /// (`macos-applescript = false`): -10004 (`errAEEventNotPermitted`) and -1708
  /// (`errAEEventNotHandled`). The worker's call; the real number is owed
  /// (`docs/MANUAL-CHECKLIST.md`). -1708 is read so only from muxFinder's own script: from
  /// another definition's it may be a missing handler (`eventNotHandledErrorNumber`).
  public static let appleScriptOffErrorNumbers: Set<Int> = [-10004, -1708]
  /// The OSA error number of an event nobody handled (`errAEEventNotHandled`, -1708): what a
  /// script answers when it lacks the handler called (`AppleScriptRunnerError.callFailed`), and
  /// what an app may answer as well; the number alone cannot tell the two apart.
  public static let eventNotHandledErrorNumber = -1708
  /// The OSA error numbers of an app that could not be launched for an Apple event: -600
  /// (`procNotFound`), -609 (`connectionInvalid`) and -10810 (LaunchServices' launch failure).
  public static let notLaunchedErrorNumbers: Set<Int> = [-600, -609, -10810]

  /// " (error -1708)", or nothing.
  static func numberText(_ number: Int?) -> String {
    number.map { " (error \($0))" } ?? ""
  }

  // MARK: - Attach and move here

  /// The start of a helper failure's line: "The launch tab in iTerm2 stopped: ", "The Terminal
  /// window stopped: ".
  public var launchStoppedPrefix: String {
    isITerm2 ? "The launch tab in iTerm2 stopped: " : "The \(name) window stopped: "
  }

  /// The helper's explanation as a row shows it: the helper wrote it for its own tab or window,
  /// so "shown above" becomes "shown in the tab" (or "… in the window").
  public func launchExplanation(_ failure: LaunchFailure) -> String {
    failure.explanation
      .replacingOccurrences(of: "is shown above", with: "is shown in the \(place)")
      .replacingOccurrences(of: "from ssh above", with: "from ssh in the \(place)")
  }

  /// No client of the new window was confirmed in time (This Mac).
  public var windowTimedOut: String {
    "The \(name) window did not attach the session in time. If \(name) shows a message, answer "
      + "it and try again."
  }

  /// A remote window still waits (a password) at the wait limit.
  public var windowWaitLimitReached: String {
    "The session's \(name) window is still waiting, for example for a password, so muxFinder "
      + "stopped watching it. Finish in the window or close it, then refresh."
  }

  /// The identity check could not be read.
  public var windowIdentityUnconfirmed: String {
    "muxFinder could not confirm which tmux session the \(name) window attached."
  }

  /// The window reached another server or session.
  public var windowIdentityMismatch: String {
    "The \(name) window reached a different tmux session than the one muxFinder listed (tmux "
      + "may have restarted), so muxFinder detached it again. Refresh and try again."
  }

  /// An earlier launch of the session in this terminal may still attach it.
  public var earlierLaunchPending: String {
    let launch = isITerm2 ? "launch tab" : "\(name) window"
    return "An earlier launch of this session may still attach it in \(name), so muxFinder did "
      + "not start another. Finish or close that \(launch), then try again."
  }

  /// The helper's early report named no terminal device.
  public var windowCannotConfirm: String {
    "\(name) gave the new window no terminal device muxFinder can check, so muxFinder could not "
      + "confirm that the window attached the session. Check the window."
  }

  /// The session's tmux clients could not be read; `reason` says why.
  public func windowClientCheckFailed(_ reason: String) -> String {
    "muxFinder could not check the session's tmux clients, so it could not confirm the \(name) "
      + "window. " + reason
  }

  /// Move here refused: the session is open in a window of this terminal already.
  public var alreadyOpenInWindow: String {
    "This session is already open in a \(name) window on this Mac, so muxFinder did not move "
      + "it. Bring that window forward, or detach it first."
  }

  /// The plain name refusal (`{`, `[` or `]` in the session's name).
  public var unsupportedSessionName: String {
    "\(name) windows can't attach a session whose name has “{”, “[” or “]”, so muxFinder opened "
      + "nothing. Rename the session, or choose iTerm2 in Settings."
  }

  // MARK: - Opening a window (`PlainTerminalWindowError`)

  /// `appNotInstalled` at the open.
  public var windowAppGone: String {
    "\(name) isn't installed any more, so muxFinder opened nothing. Install it, or choose "
      + "another terminal in Settings."
  }

  /// `appTooOld` at the open.
  public func windowAppTooOld(installed: String, minimum: String) -> String {
    "\(name) \(installed) is too old for muxFinder, so it opened nothing. Update \(name) to "
      + "\(minimum) or later, or choose another terminal in Settings."
  }

  /// `appVersionUnknown` at the open.
  public func windowVersionUnknown(minimum: String) -> String {
    "muxFinder can't tell which version of \(name) is installed, and it needs \(minimum) or "
      + "later, so it opened nothing. Update \(name), then try again."
  }

  /// `permissionDenied` at the open.
  public var windowNotAllowed: String {
    "muxFinder isn't allowed to control \(name), so it opened nothing. Allow it in System "
      + "Settings › Privacy & Security › Automation, then try again."
  }

  /// The app is not running and the open could not launch it (`appNotRunning`, or the open's
  /// launch failure with its number).
  public func windowAppNotOpened(errorNumber: Int? = nil) -> String {
    "\(name) isn't running and couldn't be opened\(Self.numberText(errorNumber)), so muxFinder "
      + "opened nothing. Open \(name), then try again."
  }

  /// `activationFailed` at the open.
  public var windowNotActivated: String {
    "macOS didn't bring \(name) to the front, so muxFinder stopped. Switch to \(name), then try "
      + "again."
  }

  /// The definition's script did not compile.
  public func windowScriptNotLoaded(errorNumber: Int) -> String {
    "muxFinder couldn't load its script for \(name)\(Self.numberText(errorNumber)), so it "
      + "opened nothing."
  }

  /// Ghostty's open refused because its AppleScript is turned off.
  public func windowAppleScriptOff(errorNumber: Int) -> String {
    "\(name)'s AppleScript is turned off\(Self.numberText(errorNumber)), so muxFinder can't "
      + "open windows there. Remove “macos-applescript = false” from \(name)'s config file and "
      + "restart \(name), then try again."
  }

  /// The open went unhandled (-1708) in a script that is not muxFinder's own: the script may
  /// have no `muxfinder_open` handler, which the number cannot tell apart from the app's own
  /// answer; for Ghostty its AppleScript may be turned off as well. Both said as possibilities.
  public func windowOpenNotHandled(errorNumber: Int) -> String {
    let opened =
      "\(name) couldn't open a window\(Self.numberText(errorNumber)), so muxFinder opened "
      + "nothing. The script of your terminal definition for \(name) may have no "
      + "“muxfinder_open” handler"
    guard kind == .ghostty else { return opened + ": check the script, then try again." }
    return opened + ", or \(name)'s AppleScript may be turned off: check the script, and "
      + "if \(name)'s config file has “macos-applescript = false”, remove it and restart "
      + "\(name). Then try again."
  } // End of func windowOpenNotHandled(errorNumber:)

  /// A handler of the definition's script raised `errorNumber`; `handler` is the one called.
  public func windowScriptCallFailed(_ handler: TerminalScriptHandler, errorNumber: Int) -> String {
    let number = Self.numberText(errorNumber)
    switch handler {
    case .open:
      return "\(name) couldn't open a window\(number), so muxFinder opened nothing. Check "
        + "\(name), then try again."
    case .focus:
      return "\(name) couldn't bring the new window forward\(number)."
    case .close:
      return "\(name) couldn't close the window\(number), so muxFinder left it open."
    }
  } // End of func windowScriptCallFailed(_:errorNumber:)

  /// A handler was called with a number of arguments its script does not take.
  public var windowScriptMismatch: String {
    "muxFinder's script for \(name) doesn't take what muxFinder sends it, so it opened nothing. "
      + "Check the terminal's definition."
  }

  /// `scriptMissing` at the open.
  public var windowNoScript: String {
    "muxFinder's definition for \(name) has no script, so it can't open windows there. Choose "
      + "another terminal in Settings."
  }

  /// `malformedReply` at the open.
  public var windowOddReply: String {
    "\(name) answered muxFinder in a way it doesn't understand, so muxFinder stopped. Look for "
      + "a window \(name) may have opened, then try again."
  }

  /// `spawnFailed` at the open; `reason` is " (No such file or directory)" or empty.
  public func windowNotStarted(_ reason: String) -> String {
    "muxFinder couldn't start \(name)\(reason), so it opened nothing. Check that \(name) is "
      + "installed, then try again."
  }

  /// `windowOfAnotherTerminal` at the open.
  public static let windowOfAnotherTerminal =
    "That window belongs to another terminal, so muxFinder left it alone and opened nothing."

  /// `definitionChanged` at the open.
  public var windowDefinitionChanged: String {
    "muxFinder's definition for \(name) changed while it worked, so it left the window alone. "
      + "Try again."
  }

  /// `notOpenedHere` at the open.
  public static let windowNotOpenedHere =
    "muxFinder didn't open that window, so it left it alone. Try again."

  /// `windowLacksFocusValue` at the open (`tty`: its terminal device; else its id).
  public func windowNoFocusValue(_ kind: TerminalFocusKind) -> String {
    let what = kind == .tty ? "its terminal device" : "an id"
    return "\(name) didn't report \(what) for the new window, so muxFinder can't bring it "
      + "forward later. Switch to \(name) to find it."
  }

  /// `windowHasNoID` at the open.
  public var windowNoID: String {
    "\(name) didn't report an id for the new window, so muxFinder can't close it later. Close "
      + "it in \(name) when you're done."
  }

  /// `windowBusy` at the open.
  public var windowStillBusy: String {
    "The \(name) window is still running something, so muxFinder left it open and opened "
      + "nothing more."
  }

  /// `windowGone` at the open.
  public var windowClosedEarly: String {
    "The \(name) window closed before muxFinder could use it. Try again."
  }

  /// `unattendedRunRefused`: `reason` is the gate's.
  public func windowUnattendedRefusal(_ reason: String) -> String {
    "muxFinder sent nothing to \(name) in an unattended run: \(reason), so it opened nothing."
  }

  // MARK: - Bringing a window forward (`TerminalFocusResult.plainWindowFailed`)

  /// The note when a focus found the app gone, too old or of an unknown version.
  public var focusAppUnusable: String {
    "\(name) can't be used now, so muxFinder brought nothing forward. Check \(name) in "
      + "Settings."
  }

  /// The note when the permission to control the app is denied.
  public var focusNotAllowed: String {
    "muxFinder isn't allowed to control \(name), so it brought nothing forward. Allow it in "
      + "System Settings › Privacy & Security › Automation."
  }

  /// The note when the app is not running.
  public var focusAppNotRunning: String {
    "\(name) isn't running, so the session's window is gone."
  }

  /// The note when macOS did not activate the app.
  public var focusNotActivated: String {
    "macOS didn't bring \(name) to the front. Switch to it to find the session's window."
  }

  /// The note when the script failed (to load, or its focus handler); `number` as in
  /// `numberText(_:)`.
  public func focusScriptFailed(errorNumber: Int?) -> String {
    "\(name) couldn't bring the window forward\(Self.numberText(errorNumber))."
  }

  /// The note when the definition cannot focus (no script, an odd reply, a refused command, a
  /// program that could not start).
  public var focusNotPossible: String {
    "muxFinder can't bring \(name) windows forward with this terminal's definition. Switch to "
      + "\(name) to find the session."
  }

  /// The note when the window lacks the value its focus needs (`tty`: its terminal device).
  public func focusNoValue(_ kind: TerminalFocusKind) -> String {
    let what = kind == .tty ? "its terminal device" : "an id"
    return "\(name) didn't report \(what) for this window, so muxFinder can't bring it forward. "
      + "Switch to \(name) to find it."
  }

  /// The note when the window is gone.
  public var focusWindowGone: String { "The \(name) window is already closed." }

  /// The note when the window belongs to a definition that changed since it opened.
  public var focusDefinitionChanged: String {
    "muxFinder's definition for \(name) changed after it opened this window, so muxFinder left "
      + "the window alone."
  }

  /// The note when the window was not opened by muxFinder or its record is gone.
  public static let focusNotOpenedHere =
    "muxFinder didn't open this window, or no longer knows it, so it brought nothing forward."

  /// The note when the window belongs to another terminal's definition.
  public static let focusOtherTerminal =
    "This window belongs to another terminal, so muxFinder left it alone."

  /// The note when the window cannot be closed or is busy (close-only errors seen at a focus).
  public var focusWindowUnusable: String {
    "muxFinder can't use this \(name) window any more. Switch to \(name) to find it."
  }

  /// The note of an unattended run's refusal; `reason` is the gate's.
  public func focusUnattendedRefusal(_ reason: String) -> String {
    "muxFinder sent nothing to \(name) in an unattended run: \(reason)."
  }

  /// The problem of an Open that found the session in this terminal's window but did not bring
  /// it forward; `reason` is the focus note.
  public func windowNotBroughtForward(_ reason: String) -> String {
    "This session is open in a \(name) window on this Mac, but muxFinder couldn't bring it "
      + "forward. " + reason
  }

  // MARK: - Detach from this Mac

  /// Nothing to detach: the backend has no window of the session.
  public var detachNothingHere: String {
    "muxFinder has no \(name) window of this session on this Mac any more, so there was nothing "
      + "to detach. The session keeps running."
  }

  /// The bound check refused: the window's client changed or ended.
  public var detachNotSent: String {
    "muxFinder did not detach this session, because the tmux client of its \(name) window "
      + "changed or ended, so nothing was sent. The session keeps running."
  }

  /// The detach ran but its outcome is unknown; `reason` says why, when known.
  public func detachNotConfirmed(_ reason: String?) -> String {
    "muxFinder asked tmux to detach the session's \(name) window, but could not tell whether it "
      + "did." + (reason.map { " " + $0 } ?? "") + " The session keeps running; check the window."
  }

  /// The detach could not be prepared; `reason` says why, when known.
  public func detachNotPrepared(_ reason: String?) -> String {
    "muxFinder could not prepare the detach of this session's \(name) window, so it detached "
      + "nothing." + (reason.map { " " + $0 } ?? "")
  }

  // MARK: - Detach other clients (PLAN.md D37)

  /// "1 other client", "2 other clients".
  static func otherClients(_ count: Int) -> String {
    count == 1 ? "1 other client" : "\(count) other clients"
  }

  /// The kept window no longer holds the session (`notAttachedHere`): nothing was sent.
  public var othersNotHere: String {
    "muxFinder's \(name) window no longer holds this session, so muxFinder detached no other "
      + "client. The session keeps running."
  }

  /// Why a run stopped: this Mac's window no longer held the session the same way.
  public var othersKeptChanged: String {
    "this Mac's \(name) window no longer held the session the same way, so muxFinder sent "
      + "nothing more."
  }

  /// Why a run stopped: the session's clients could not be read; `reason` says why.
  public static func othersListingFailed(_ reason: String) -> String {
    "muxFinder could not read the session's clients. " + reason
  }

  /// Why a run stopped: a detach could not run; `reason` says why.
  public static func othersDetachNotRun(_ reason: String) -> String {
    "a detach could not be sent. " + reason
  }

  /// Why a run stopped: a detach failed and may have gone through; `reason` says why.
  public static func othersDetachUncertain(_ reason: String) -> String {
    "a detach failed and may have gone through. " + reason
  }

  /// A run that stopped with no other client detached, which is known.
  public static func othersNoneDetached(_ reason: String) -> String {
    "muxFinder detached no other client: " + reason + " The session keeps running."
  }

  /// "Stopped after detaching 2 other clients": a run that stopped partway, its count known.
  public static func othersStopped(after count: Int, _ reason: String) -> String {
    "Stopped after detaching \(otherClients(count)): " + reason + " The session keeps running."
  }

  /// "Some may have been detached": a run that stopped with its count unknown (`atLeast` were
  /// confirmed before).
  public static func othersSomeMayHaveBeen(atLeast count: Int, _ reason: String) -> String {
    let known = count > 0 ? " At least \(otherClients(count)) \(count == 1 ? "was" : "were")." : ""
    return "Stopped detaching the session's other clients. Some may have been detached: "
      + reason + known + " The session keeps running."
  }
} // End of extension TerminalWording
