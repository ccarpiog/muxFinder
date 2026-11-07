import Foundation
import MuxFinderCore

/// Why an action on a session failed, in plain English, and what the row offers to recover
/// (PLAN.md D25, D37). Every failure path of an attach, a move here, a detach, a "Detach other
/// clients…" and "Show tab" has its own message (a unit test checks that they are pairwise
/// distinct), and none holds user data beyond what the popover shows anyway. The plain
/// backend's failures are worded for the terminal that ran the action (PLAN.md D38 *The UI
/// (I-12d2)*, `SessionProblemTerminal.swift`); iTerm2's are as before.
public struct SessionProblem: Sendable, Hashable {
  /// A button under the message.
  public enum Recovery: Sendable, Hashable {
    /// "Try again": repeats the failed action (a move here and a "Detach other clients…" ask
    /// for confirmation again, in the popover only, so the session switcher does not offer it
    /// for them).
    case retry
    /// "Refresh": clears the failure and refreshes the session's host.
    case refresh
    /// "Show tab": brings forward the launch tab muxFinder opened (its iTerm2 session id).
    case showTab(String)
    /// "Bring forward": attaches again, which focuses the attachment that exists already.
    case bringForward
    /// "Detach from this Mac": detaches the session's attachments in this Mac's iTerm2.
    case detachHere
    /// "Open Settings": the host's settings (tmux path, SSH destination), or the terminal
    /// picker for a terminal that cannot be used.
    case openSettings
    /// "Show window": brings forward the plain window the failed launch opened (PLAN.md D38
    /// *The UI (I-12d2)*; "Show tab"'s counterpart), through the chosen terminal's backend.
    case showWindow(PlainTerminalWindow)
    /// "Open System Settings…": Privacy & Security › Automation, for a terminal app muxFinder
    /// is not allowed to control (an URL open, no Apple event).
    case openAutomationSettings

    /// The button's title, sentence case.
    public var title: String {
      switch self {
      case .retry: return "Try again"
      case .refresh: return "Refresh"
      case .showTab: return "Show tab"
      case .bringForward: return "Bring forward"
      case .detachHere: return "Detach from this Mac"
      case .openSettings: return "Open Settings"
      case .showWindow(let window):
        return TerminalWording(definition: window.openedBy.definition).showTitle
      case .openAutomationSettings: return "Open System Settings…"
      }
    } // End of var title
  } // End of enum Recovery

  /// The explanation.
  public var message: String
  /// The buttons offered, in order (at most two).
  public var recoveries: [Recovery]
  /// The System Settings fix-it for an iTerm2 permission or API problem, if any (PLAN.md D23).
  public var fixIt: FixIt?

  /// Creates a problem.
  public init(message: String, recoveries: [Recovery] = [.retry], fixIt: FixIt? = nil) {
    self.message = message
    self.recoveries = recoveries
    self.fixIt = fixIt
  }

  // MARK: - Attach and move here

  /// The problem an attach or a move here that ended `failure` shows. `launchTab` is the launch
  /// tab's iTerm2 session, when iTerm2 opened one (it gets "Show tab" where the tab explains
  /// more or still waits). `wording` is the terminal the action ran in: with iTerm2's every
  /// line is as before; with a plain terminal's, `plainAttach(_:wording:window:)` words it for
  /// that terminal, `window` (the window the launch opened) getting "Show window", and
  /// `definitionSource` (where that terminal's definition came from) saying whether its script is
  /// muxFinder's own (`builtIn`, which defines every handler) or may lack one. The plain backend's
  /// window failures are worded by their own app name whatever `wording` is.
  public static func attach(
    _ failure: AttachFailure,
    launchTab: String? = nil,
    wording: TerminalWording = .iTerm2,
    window: PlainTerminalWindow? = nil,
    definitionSource: TerminalDefinitionSource = .builtIn
  ) -> SessionProblem {
    guard wording.isITerm2 else {
      return plainAttach(
        failure, wording: wording, window: window, definitionSource: definitionSource)
    }
    let fixIt = FixIt(failure: failure)
    let showTab = launchTab.map { [Recovery.showTab($0)] } ?? []
    switch failure {
    case .invalidDestination, .tmuxMissing:
      return SessionProblem(message: failure.message, recoveries: [.openSettings, .retry])
    case .sessionGone, .sessionChanged, .identityMismatch:
      return SessionProblem(message: failure.message, recoveries: [.refresh])
    case .helperFailed(let launchFailure):
      return SessionProblem(
        message: "The launch tab in iTerm2 stopped: " + tabExplanation(launchFailure),
        recoveries: showTab + [.retry])
    case .timedOut:
      return SessionProblem(message: failure.message, recoveries: showTab + [.retry])
    case .waitLimitReached:
      return SessionProblem(
        message: failure.message, recoveries: showTab.isEmpty ? [.refresh] : showTab)
    case .alreadyAttachedHere:
      return SessionProblem(message: failure.message, recoveries: [.bringForward, .detachHere])
    case .iTerm2, .attachmentCheckFailed, .identityCheckFailed:
      return SessionProblem(message: failure.message, recoveries: [.retry], fixIt: fixIt)
    case .discoveryFailed, .launchStore, .helperEnded, .cancelled, .attachmentChanged,
      .moveHereNotConfirmed, .possiblyAttachedHere, .earlierLaunchPending:
      return SessionProblem(message: failure.message, recoveries: [.retry])
    // The plain backend's failures (PLAN.md D38) never come from iTerm2's backend; their own
    // lines are `plainAttach(_:wording:window:)`'s. A window failure is worded by its app.
    case .terminalWindow(let error):
      return terminalWindow(error, kind: .other)
    case .alreadyOpenInTerminal:
      return SessionProblem(message: failure.message, recoveries: [.bringForward, .detachHere])
    case .cannotConfirmHere, .clientCheckFailed:
      return SessionProblem(message: failure.message, recoveries: [.retry])
    case .unsupportedSessionName:
      return SessionProblem(message: failure.message, recoveries: [.refresh])
    }
  } // End of static func attach(_:launchTab:wording:window:definitionSource:)

  /// The problem an Open shows when it found the session open in this Mac's iTerm2 already
  /// (the core's `focused`) but did not bring its tab forward: `error` is how iTerm2 refused or
  /// failed to answer the activation (with D23's fix-it for an iTerm2 permission or API error),
  /// `nil` when no tab of the connection appeared in time (`ActivationOutcome.noTab`). The
  /// attachment exists, so the row keeps it (Detach stays offered); "Try again" repeats the
  /// Open, which focuses it again.
  public static func notBroughtForward(_ error: ITerm2Error?) -> SessionProblem {
    guard let error else {
      return SessionProblem(
        message: "This session is open in iTerm2 on this Mac, but muxFinder found no tab of it "
          + "to bring forward. Look for it in iTerm2, or try again.")
    }
    return SessionProblem(
      message: "This session is open in iTerm2 on this Mac, but iTerm2 did not bring its tab "
        + "forward. Switch to iTerm2 to find it, or try again.",
      fixIt: FixIt(failure: .iTerm2(error)))
  } // End of static func notBroughtForward(_:)

  /// The helper's explanation as the popover shows it: the helper wrote it for its own tab, so
  /// "shown above" becomes "shown in the tab".
  static func tabExplanation(_ failure: LaunchFailure) -> String {
    failure.explanation
      .replacingOccurrences(of: "is shown above", with: "is shown in the tab")
      .replacingOccurrences(of: "from ssh above", with: "from ssh in the tab")
  }

  /// The problem shown when the attach coordinator cannot be built (the helper is missing or
  /// sits on a path iTerm2 cannot be given): `message` is the reason; nothing can be retried.
  public static func unavailable(_ message: String) -> SessionProblem {
    SessionProblem(message: message, recoveries: [])
  }

  /// The problem every session action shows while the terminal setting names a terminal that
  /// cannot be used (PLAN.md D38, Phase I-12c3a; requirement 8): nothing was written, launched
  /// or sent, and no other terminal was used instead. "Open Settings" goes to the picker. With
  /// the choice's `wording` (its definition's name, PLAN.md D38 *The UI (I-12d2)*) the line
  /// names it: "The chosen terminal, Ghostty, isn't installed. …"; an id no definition has, or
  /// no wording, keeps the core's sentence, which quotes the id.
  public static func terminalUnavailable(
    _ failure: TerminalChoiceUnavailable,
    wording: TerminalWording? = nil
  ) -> SessionProblem {
    let message: String
    switch (failure.reason, wording) {
    case (.unknownID, _), (_, nil):
      message = failure.message
    case (.notInstalled, let wording?):
      message = wording.unavailableNotInstalled
    case (.versionTooOld(let minimum), let wording?):
      message = wording.unavailableTooOld(minimum: minimum.text)
    case (.versionUnknown(let minimum), let wording?):
      message = wording.unavailableVersionUnknown(minimum: minimum.text)
    }
    return SessionProblem(message: message, recoveries: [.openSettings])
  } // End of static func terminalUnavailable(_:wording:)

  /// The problem a session switcher row the engine does not list shows when it is opened
  /// again (Return, "Try again", "Bring forward") after its host was turned off or removed:
  /// nothing was opened (PLAN.md D32).
  public static let hostNotTurnedOn = SessionProblem(
    message: "This session's host is no longer turned on in muxFinder, so nothing was opened. "
      + "Turn it on in Settings, then try again.",
    recoveries: [.openSettings, .retry])

  // MARK: - Detach

  /// The problem a "Detach from this Mac" that ended `result` shows; `nil` when it detached.
  /// `wording` is the terminal it ran in: iTerm2's lines as before, a plain terminal's
  /// `plainDetach(_:wording:)`.
  public static func detach(
    _ result: SessionDetachResult,
    wording: TerminalWording = .iTerm2
  ) -> SessionProblem? {
    guard wording.isITerm2 else { return plainDetach(result, wording: wording) }
    switch result.outcome {
    case .detached:
      return nil
    case .nothingAttached:
      return SessionProblem(
        message: "muxFinder found no tab showing this session in iTerm2 on this Mac, so there was "
          + "nothing to detach. The session keeps running.", recoveries: [.refresh])
    case .notSent:
      return SessionProblem(
        message: "muxFinder did not detach this session, because its tab in iTerm2 changed or did "
          + "not answer, so nothing was sent. The session keeps running.")
    case .notClosed:
      return SessionProblem(
        message: "muxFinder asked tmux to detach, but the session's tab in iTerm2 did not close "
          + "in time. The session keeps running; check iTerm2.")
    case .cancelled:
      return SessionProblem(
        message: "Detaching was cancelled before muxFinder sent anything. The session keeps "
          + "running.")
    case .checkFailed:
      let reason: String
      switch result.checkFailure {
      case .attachmentCheckFailed(let error)?:
        reason = error.errorDescription.map { " " + $0 } ?? ""
      case let failure?:
        reason = " " + failure.message
      case nil:
        reason = ""
      }
      return SessionProblem(
        message: "muxFinder could not check which iTerm2 tabs show this session, so it detached "
          + "nothing." + reason,
        fixIt: result.checkFailure.flatMap(FixIt.init(failure:)))
    }
  } // End of static func detach(_:wording:)

  // MARK: - Detach other clients

  /// The problem a "Detach other clients…" that ended `result` shows (PLAN.md D37); `nil` when
  /// it detached, found nothing left to detach (the row's informational line) or was cancelled
  /// (the row shows nothing). "Try again" shows the confirmation again. `wording` is the
  /// terminal it ran in: iTerm2's lines as before, a plain terminal's
  /// `plainDetachOtherClients(_:wording:)` (a run stopped partway says how many it detached, or
  /// that some may have been, never "none" when that is unproven).
  public static func detachOtherClients(
    _ result: DetachOtherClientsResult,
    wording: TerminalWording = .iTerm2
  ) -> SessionProblem? {
    guard wording.isITerm2 else { return plainDetachOtherClients(result, wording: wording) }
    let keepsRunning = " The session keeps running."
    switch result.outcome {
    case .detached, .nothingToDetach, .cancelled:
      return nil
    case .notAttachedHere:
      return SessionProblem(
        message: "This Mac's iTerm2 no longer shows this session, so muxFinder detached no other "
          + "client." + keepsRunning, recoveries: [.refresh])
    case .identityChanged:
      return SessionProblem(
        message: "muxFinder detached no other client, because this Mac's tab of the session in "
          + "iTerm2 changed, so nothing was sent." + keepsRunning, recoveries: [.refresh])
    case .notConfirmed:
      return SessionProblem(
        message: "muxFinder detached nothing, because the confirmation was for another session.",
        recoveries: [.refresh])
    case .checkFailed(.send(.tmuxCommandFailed)):
      return SessionProblem(
        message: "tmux refused to detach one of the other clients (it may have just left), and "
          + "iTerm2 may have ended this Mac's attachment of the session too." + keepsRunning,
        recoveries: [.refresh])
    case .checkFailed(let problem):
      return detachOtherClientsCheckFailed(problem)
    }
  } // End of static func detachOtherClients(_:wording:)

  /// The problem of a "Detach other clients…" that could not check or send something (other
  /// than a detach tmux refused): its message, "Try again" and "Refresh", and D23's fix-it for
  /// an iTerm2 permission or API error.
  static func detachOtherClientsCheckFailed(_ problem: DetachOtherClientsProblem) -> SessionProblem
  {
    let message: String
    let fixIt: FixIt?
    switch problem {
    case .attachmentCheck(let failure):
      let reason: String
      if case .attachmentCheckFailed(let error) = failure {
        reason = error.errorDescription.map { " " + $0 } ?? ""
      } else {
        reason = " " + failure.message
      }
      message =
        "muxFinder could not check which iTerm2 tabs show this session, so it detached no other "
        + "client." + reason
      fixIt = FixIt(failure: failure)
    case .identityCheck(let reason):
      message =
        "muxFinder could not check this Mac's tab of the session in iTerm2, so it detached no "
        + "other client."
      if case .requestFailed(let error) = reason {
        fixIt = FixIt(error: error)
      } else {
        fixIt = nil
      }
    case .clientListing(let error):
      message =
        "muxFinder could not read the session's other clients through iTerm2, so it stopped "
        + "detaching them." + (error?.errorDescription.map { " " + $0 } ?? "")
      fixIt = FixIt(error: error)
    case .send(let error):
      message =
        "muxFinder could not send the detach through iTerm2, so some of the session's other "
        + "clients may still be attached." + (error.errorDescription.map { " " + $0 } ?? "")
      fixIt = FixIt(error: error)
    // The plain backend's problems (PLAN.md D38) never come from iTerm2's backend; their own
    // lines are `plainDetachOtherClients(_:wording:)`'s.
    case .plainClientListing(let failure):
      message =
        "muxFinder could not read the session's other clients, so it stopped detaching them. "
        + failure.message
      fixIt = nil
    case .plainDetach(let failure):
      message =
        "muxFinder could not finish detaching the session's other clients, so some may still "
        + "be attached. " + failure.message
      fixIt = nil
    }
    return SessionProblem(message: message, recoveries: [.retry, .refresh], fixIt: fixIt)
  } // End of static func detachOtherClientsCheckFailed(_:)

  // MARK: - Show tab

  /// The note shown under a session when "Show tab" did not bring its launch tab forward;
  /// `nil` when it did.
  public static func showTabNote(_ result: LaunchTabShowResult) -> String? {
    switch result {
    case .shown:
      return nil
    case .notOpenedHere:
      return "muxFinder only brings forward tabs it opened itself, and it no longer knows this one."
    case .failed:
      return "iTerm2 did not bring the launch tab forward. It may have closed."
    }
  }

  /// The note shown under a session when a focus through the terminal seam (PLAN.md D38,
  /// Phase I-12c3a: "Show tab", a plain window, an app the session is open in on this Mac) did
  /// not bring it forward; `nil` when it did. A launch tab's is `showTabNote(_:)`'s, unchanged;
  /// a plain window's is `windowFocusNote(_:kind:)`'s, worded by its app (PLAN.md D38 *The UI
  /// (I-12d2)*).
  public static func focusNote(_ result: TerminalFocusResult) -> String? {
    switch result {
    case .launchTab(let shown):
      return showTabNote(shown)
    case .plainWindowFocused, .appActivation(.activated):
      return nil
    case .plainWindowFailed(let error):
      return windowFocusNote(error, kind: .other)
    case .handleOfAnotherTerminal:
      return "That window belongs to a terminal muxFinder doesn't use now, so nothing was "
        + "brought forward."
    case .appActivation(.notRunning):
      return "That app isn't running any more, so muxFinder brought nothing forward."
    case .appActivation(.refused):
      return "macOS didn't bring that app forward. Switch to it to find the session."
    }
  } // End of static func focusNote(_:)
}

/// A banner above the host list: a session vanished or changed between the listing and an
/// action on it (PLAN.md D25). The host's list is refreshed when it appears.
public struct SessionBanner: Sendable, Hashable, Identifiable {
  /// What happened.
  public enum Kind: Sendable, Hashable {
    /// The session ended (or its tmux server stopped) after muxFinder listed it.
    case vanished
    /// The session's id now names another session or server (tmux restarted, for example).
    case changed
  }

  /// Tells banners apart.
  public var id: Int
  /// What happened.
  public var kind: Kind
  /// The session's name as the popover listed it.
  public var sessionName: String
  /// The host's display name.
  public var hostName: String

  /// Creates a banner.
  public init(id: Int, kind: Kind, sessionName: String, hostName: String) {
    self.id = id
    self.kind = kind
    self.sessionName = sessionName
    self.hostName = hostName
  }

  /// The kind for an action failure, or `nil` when the failure is not about the session
  /// vanishing or changing (`AttachFailure.triggersRefresh`).
  public static func kind(for failure: AttachFailure) -> Kind? {
    switch failure {
    case .sessionGone: return .vanished
    case .sessionChanged, .identityMismatch: return .changed
    default: return nil
    }
  }

  /// The banner's text.
  public var text: String {
    switch kind {
    case .vanished:
      return "“\(sessionName)” on \(hostName) ended before muxFinder could open it. The list was "
        + "refreshed."
    case .changed:
      return "“\(sessionName)” on \(hostName) changed since muxFinder listed it (tmux may have "
        + "restarted), so muxFinder did not open it. Check the refreshed list and try again."
    }
  }
}
