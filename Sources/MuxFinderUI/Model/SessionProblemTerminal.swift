import Foundation
import MuxFinderCore

// The plain backend's failures in the popover and the switcher (PLAN.md D38 *The UI
// (I-12d2)*): each `AttachFailure`, `PlainTerminalWindowError`, detach outcome and "Detach other
// clients…" outcome mapped, by an exhaustive switch with no `default:`, to its own line (from
// `TerminalWording`) and recoveries; none falls to a generic line.

extension SessionProblem {
  // MARK: - Attach and move here

  /// The problem of an attach or a move here that ended `failure` in the plain terminal
  /// `wording` names; `window` is the window the launch opened, if any (it gets "Show window"
  /// where the window explains more or still waits); `definitionSource` is where that
  /// terminal's definition came from (`terminalWindow(_:kind:definitionSource:)`). iTerm2's own
  /// failures (its API, its attachment index) keep iTerm2's lines: the plain backend never
  /// reports them.
  static func plainAttach(
    _ failure: AttachFailure,
    wording: TerminalWording,
    window: PlainTerminalWindow?,
    definitionSource: TerminalDefinitionSource = .builtIn
  ) -> SessionProblem {
    let showWindow = window.map { [Recovery.showWindow($0)] } ?? []
    switch failure {
    case .invalidDestination, .tmuxMissing:
      return SessionProblem(message: failure.message, recoveries: [.openSettings, .retry])
    case .sessionGone, .sessionChanged:
      return SessionProblem(message: failure.message, recoveries: [.refresh])
    case .identityMismatch:
      return SessionProblem(message: wording.windowIdentityMismatch, recoveries: [.refresh])
    case .helperFailed(let launchFailure):
      return SessionProblem(
        message: wording.launchStoppedPrefix + wording.launchExplanation(launchFailure),
        recoveries: showWindow + [.retry])
    case .timedOut:
      return SessionProblem(message: wording.windowTimedOut, recoveries: showWindow + [.retry])
    case .waitLimitReached:
      return SessionProblem(
        message: wording.windowWaitLimitReached,
        recoveries: showWindow.isEmpty ? [.refresh] : showWindow)
    case .identityCheckFailed:
      return SessionProblem(message: wording.windowIdentityUnconfirmed, recoveries: [.retry])
    case .earlierLaunchPending:
      return SessionProblem(message: wording.earlierLaunchPending, recoveries: [.retry])
    case .terminalWindow(let error):
      return terminalWindow(error, kind: wording.kind, definitionSource: definitionSource)
    case .cannotConfirmHere:
      return SessionProblem(
        message: wording.windowCannotConfirm, recoveries: showWindow + [.retry])
    case .clientCheckFailed(let check):
      return SessionProblem(
        message: wording.windowClientCheckFailed(check.message), recoveries: [.retry])
    case .alreadyOpenInTerminal(let open):
      return SessionProblem(
        message: TerminalWording(definition: open.openedBy.definition).alreadyOpenInWindow,
        recoveries: [.bringForward, .detachHere])
    case .unsupportedSessionName:
      return SessionProblem(message: wording.unsupportedSessionName, recoveries: [.refresh])
    case .alreadyAttachedHere, .iTerm2, .attachmentCheckFailed, .attachmentChanged,
      .possiblyAttachedHere:
      // iTerm2's own: its index or its API.
      return attach(failure)
    case .discoveryFailed, .launchStore, .helperEnded, .cancelled, .moveHereNotConfirmed:
      return SessionProblem(message: failure.message, recoveries: [.retry])
    }
  } // End of static func plainAttach(_:wording:window:definitionSource:)

  /// The problem of a window the plain terminal could not open (`PlainTerminalWindowError`),
  /// worded by the error's own app name; `kind` is the terminal's kind (Ghostty's AppleScript
  /// turned off is told apart only for Ghostty), `definitionSource` where its definition came
  /// from (a script that is not muxFinder's own may lack a handler:
  /// `scriptFailed(_:_:definitionSource:)`). Every case has its own line: an app gone or too old
  /// offers "Open Settings", a refused permission "Open System Settings…" (Privacy & Security ›
  /// Automation).
  static func terminalWindow(
    _ error: PlainTerminalWindowError,
    kind: TerminalWording.Kind,
    definitionSource: TerminalDefinitionSource = .builtIn
  ) -> SessionProblem {
    /// The wording of `app` of `kind`.
    func app(_ name: String) -> TerminalWording {
      TerminalWording(name: name, kind: kind == .iTerm2 ? .other : kind)
    }
    switch error {
    case .appNotInstalled(let name):
      return SessionProblem(message: app(name).windowAppGone, recoveries: [.openSettings])
    case .appTooOld(let name, let installed, let minimum):
      return SessionProblem(
        message: app(name).windowAppTooOld(installed: installed, minimum: minimum),
        recoveries: [.openSettings, .retry])
    case .appVersionUnknown(let name, let minimum):
      return SessionProblem(
        message: app(name).windowVersionUnknown(minimum: minimum),
        recoveries: [.retry, .openSettings])
    case .permissionDenied(let name):
      return SessionProblem(
        message: app(name).windowNotAllowed, recoveries: [.openAutomationSettings, .retry])
    case .appNotRunning(let name):
      return SessionProblem(message: app(name).windowAppNotOpened(), recoveries: [.retry])
    case .activationFailed(let name):
      return SessionProblem(message: app(name).windowNotActivated, recoveries: [.retry])
    case .launchCommandRefused(let refusal):
      // Its own sentence per refusal (the helper's path); moving muxFinder is the fix.
      return SessionProblem(message: refusal.message, recoveries: [])
    case .scriptFailed(let name, let failure):
      return scriptFailed(app(name), failure, definitionSource: definitionSource)
    case .scriptMissing(let name):
      return SessionProblem(message: app(name).windowNoScript, recoveries: [.openSettings])
    case .malformedReply(let name, _):
      return SessionProblem(message: app(name).windowOddReply, recoveries: [.retry])
    case .spawnFailed(let name, let failure):
      return SessionProblem(
        message: app(name).windowNotStarted(PlainTerminalWindowError.reason(of: failure)),
        recoveries: [.retry, .openSettings])
    case .windowOfAnotherTerminal:
      return SessionProblem(message: TerminalWording.windowOfAnotherTerminal, recoveries: [.retry])
    case .definitionChanged(let name):
      return SessionProblem(message: app(name).windowDefinitionChanged, recoveries: [.retry])
    case .notOpenedHere:
      return SessionProblem(message: TerminalWording.windowNotOpenedHere, recoveries: [.retry])
    case .windowLacksFocusValue(let name, let focus):
      return SessionProblem(message: app(name).windowNoFocusValue(focus), recoveries: [.retry])
    case .windowHasNoID(let name):
      return SessionProblem(message: app(name).windowNoID, recoveries: [.retry])
    case .windowBusy(let name):
      return SessionProblem(message: app(name).windowStillBusy, recoveries: [.retry])
    case .windowGone(let name):
      return SessionProblem(message: app(name).windowClosedEarly, recoveries: [.retry])
    case .unattendedRunRefused(let name, let refusal):
      return SessionProblem(
        message: app(name).windowUnattendedRefusal(refusal.message), recoveries: [.retry])
    }
  } // End of static func terminalWindow(_:kind:definitionSource:)

  /// A script failure at the open: its script not loading, an open nobody handled in a script
  /// that is not muxFinder's own, Ghostty's AppleScript turned off, an app that could not be
  /// launched for the event, a handler's error, or a call with the wrong arguments.
  ///
  /// -1708 (`errAEEventNotHandled`) is both what a script answers for a handler it lacks and
  /// what an app may answer: the number cannot tell them apart (PLAN.md D38 *The UI (I-12d2)*,
  /// review fix). muxFinder's own scripts (`definitionSource` `builtIn`) define every handler,
  /// so there it is the app's answer, which for Ghostty is taken as its AppleScript turned off;
  /// from any other definition's script (a user's, or an override) the line names both causes
  /// as possibilities (`windowOpenNotHandled(errorNumber:)`), never a definitive diagnosis.
  static func scriptFailed(
    _ app: TerminalWording,
    _ failure: AppleScriptRunnerError,
    definitionSource: TerminalDefinitionSource = .builtIn
  ) -> SessionProblem {
    switch failure {
    case .compileFailed(let number):
      return SessionProblem(
        message: app.windowScriptNotLoaded(errorNumber: number), recoveries: [.retry])
    case .callFailed(.open, let number)
    where number == TerminalWording.eventNotHandledErrorNumber && definitionSource != .builtIn:
      return SessionProblem(
        message: app.windowOpenNotHandled(errorNumber: number),
        recoveries: [.retry, .openSettings])
    case .callFailed(.open, let number)
    where app.kind == .ghostty && TerminalWording.appleScriptOffErrorNumbers.contains(number):
      return SessionProblem(
        message: app.windowAppleScriptOff(errorNumber: number), recoveries: [.retry])
    case .callFailed(.open, let number)
    where TerminalWording.notLaunchedErrorNumbers.contains(number):
      return SessionProblem(
        message: app.windowAppNotOpened(errorNumber: number), recoveries: [.retry])
    case .callFailed(let handler, let number):
      return SessionProblem(
        message: app.windowScriptCallFailed(handler, errorNumber: number), recoveries: [.retry])
    case .wrongArgumentCount:
      return SessionProblem(message: app.windowScriptMismatch, recoveries: [.openSettings])
    }
  } // End of static func scriptFailed(_:_:definitionSource:)

  // MARK: - Bringing forward

  /// The note under a session when a plain window was not brought forward, worded by the
  /// error's app (`kind` as in `terminalWindow(_:kind:)`). Every case has its own branch.
  static func windowFocusNote(_ error: PlainTerminalWindowError, kind: TerminalWording.Kind)
    -> String
  {
    /// The wording of `app` of `kind`.
    func app(_ name: String) -> TerminalWording {
      TerminalWording(name: name, kind: kind == .iTerm2 ? .other : kind)
    }
    switch error {
    case .appNotInstalled(let name), .appTooOld(let name, _, _),
      .appVersionUnknown(let name, _):
      return app(name).focusAppUnusable
    case .permissionDenied(let name):
      return app(name).focusNotAllowed
    case .appNotRunning(let name):
      return app(name).focusAppNotRunning
    case .activationFailed(let name):
      return app(name).focusNotActivated
    case .scriptFailed(let name, let failure):
      return app(name).focusScriptFailed(errorNumber: failure.errorNumber)
    case .scriptMissing(let name), .malformedReply(let name, _), .spawnFailed(let name, _):
      return app(name).focusNotPossible
    case .launchCommandRefused(let refusal):
      return refusal.message
    case .windowOfAnotherTerminal:
      return TerminalWording.focusOtherTerminal
    case .definitionChanged(let name):
      return app(name).focusDefinitionChanged
    case .notOpenedHere:
      return TerminalWording.focusNotOpenedHere
    case .windowLacksFocusValue(let name, let focus):
      return app(name).focusNoValue(focus)
    case .windowHasNoID(let name), .windowBusy(let name):
      return app(name).focusWindowUnusable
    case .windowGone(let name):
      return app(name).focusWindowGone
    case .unattendedRunRefused(let name, let refusal):
      return app(name).focusUnattendedRefusal(refusal.message)
    }
  } // End of static func windowFocusNote(_:kind:)

  /// The note under a session when a focus through the terminal seam did not bring it forward,
  /// for the terminal `wording` names (its kind words a plain window's error); `nil` when it
  /// did. `focusNote(_:)` with iTerm2's wording.
  public static func focusNote(_ result: TerminalFocusResult, wording: TerminalWording) -> String? {
    if case .plainWindowFailed(let error) = result {
      return windowFocusNote(error, kind: wording.kind)
    }
    return focusNote(result)
  }

  /// The problem of an Open that found the session in the backend's own window and did not
  /// bring it forward (`focus` is how that went): the attachment exists, so the row keeps it;
  /// "Try again" repeats the Open, which focuses it again.
  static func windowNotBroughtForward(
    _ focus: TerminalFocusResult,
    wording: TerminalWording
  ) -> SessionProblem {
    let reason = focusNote(focus, wording: wording) ?? ""
    return SessionProblem(message: wording.windowNotBroughtForward(reason), recoveries: [.retry])
  }

  /// The problem of an Open that found the session open in `app` on this Mac whose activation
  /// did not bring it forward (`activation`): "Try again" repeats the Open.
  static func appNotBroughtForward(
    _ activation: TerminalAppActivation,
    app: TerminalWording
  ) -> SessionProblem {
    SessionProblem(
      message: app.appNotBroughtForward(running: activation != .notRunning),
      recoveries: activation == .notRunning ? [.refresh] : [.retry])
  }

  // MARK: - Detach

  /// The problem a plain "Detach from this Mac" that ended `result` shows in the terminal
  /// `wording` names; `nil` when it detached.
  static func plainDetach(_ result: SessionDetachResult, wording: TerminalWording)
    -> SessionProblem?
  {
    let reason = result.plainDetach?.failure?.message
    switch result.outcome {
    case .detached:
      return nil
    case .nothingAttached:
      return SessionProblem(message: wording.detachNothingHere, recoveries: [.refresh])
    case .notSent:
      return SessionProblem(message: wording.detachNotSent, recoveries: [.refresh])
    case .notClosed:
      return SessionProblem(
        message: wording.detachNotConfirmed(reason), recoveries: [.retry, .refresh])
    case .cancelled:
      return detach(result)
    case .checkFailed:
      let check = result.checkFailure?.message ?? reason
      return SessionProblem(message: wording.detachNotPrepared(check), recoveries: [.retry])
    }
  } // End of static func plainDetach(_:wording:)

  // MARK: - Detach other clients

  /// The problem a plain "Detach other clients…" that ended `result` shows in the terminal
  /// `wording` names (PLAN.md D37, D38): `nil` as for iTerm2 (detached, nothing to detach,
  /// cancelled). A run that stopped says "Stopped after detaching N" when its count is known
  /// (`detachedClients`, every other detach refused or never sent), "detached no other client"
  /// only when none was, and "Some may have been detached" when a detach that failed may have
  /// gone through; never "none detached" when that is unproven.
  static func plainDetachOtherClients(
    _ result: DetachOtherClientsResult,
    wording: TerminalWording
  ) -> SessionProblem? {
    let count = result.detachedClients
    /// The line for a run that stopped for `reason`, its count known unless `uncertain`.
    func stopped(_ reason: String, uncertain: Bool = false) -> String {
      if uncertain { return TerminalWording.othersSomeMayHaveBeen(atLeast: count, reason) }
      return count > 0
        ? TerminalWording.othersStopped(after: count, reason)
        : TerminalWording.othersNoneDetached(reason)
    }
    switch result.outcome {
    case .detached, .nothingToDetach, .cancelled:
      return nil
    case .notAttachedHere:
      return SessionProblem(message: wording.othersNotHere, recoveries: [.refresh])
    case .notConfirmed:
      return detachOtherClients(result)
    case .identityChanged:
      return SessionProblem(message: stopped(wording.othersKeptChanged), recoveries: [.refresh])
    case .checkFailed(.plainClientListing(let failure)):
      return SessionProblem(
        message: stopped(TerminalWording.othersListingFailed(failure.message)),
        recoveries: [.retry, .refresh])
    case .checkFailed(.plainDetach(let failure)):
      let reason =
        failure.mayHaveRun
        ? TerminalWording.othersDetachUncertain(failure.message)
        : TerminalWording.othersDetachNotRun(failure.message)
      return SessionProblem(
        message: stopped(reason, uncertain: failure.mayHaveRun), recoveries: [.retry, .refresh])
    case .checkFailed(.attachmentCheck), .checkFailed(.identityCheck),
      .checkFailed(.clientListing), .checkFailed(.send):
      // iTerm2's own problems: the plain backend never reports them.
      return detachOtherClients(result)
    }
  } // End of static func plainDetachOtherClients(_:wording:)
} // End of extension SessionProblem
