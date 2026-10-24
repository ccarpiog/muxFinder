import Foundation
import MuxFinderCore

/// Why an action on a session failed, in plain English, and what the row offers to recover
/// (PLAN.md D25). Every failure path of an attach, a move here, a detach and "Show tab" has its
/// own message (a unit test checks that they are pairwise distinct), and none holds user data
/// beyond what the popover shows anyway.
public struct SessionProblem: Sendable, Hashable {
  /// A button under the message.
  public enum Recovery: Sendable, Hashable {
    /// "Try again": repeats the failed action (a move here asks for confirmation again).
    case retry
    /// "Refresh": clears the failure and refreshes the session's host.
    case refresh
    /// "Show tab": brings forward the launch tab muxFinder opened (its iTerm2 session id).
    case showTab(String)
    /// "Bring forward": attaches again, which focuses the attachment that exists already.
    case bringForward
    /// "Detach from this Mac": detaches the session's attachments in this Mac's iTerm2.
    case detachHere
    /// "Open Settings": the host's settings (tmux path, SSH destination).
    case openSettings

    /// The button's title, sentence case.
    public var title: String {
      switch self {
      case .retry: return "Try again"
      case .refresh: return "Refresh"
      case .showTab: return "Show tab"
      case .bringForward: return "Bring forward"
      case .detachHere: return "Detach from this Mac"
      case .openSettings: return "Open Settings"
      }
    }
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
  /// more or still waits).
  public static func attach(_ failure: AttachFailure, launchTab: String? = nil) -> SessionProblem {
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
    }
  } // End of static func attach(_:launchTab:)

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

  /// The problem a session switcher row the engine does not list shows when it is opened
  /// again (Return, "Try again", "Bring forward") after its host was turned off or removed:
  /// nothing was opened (PLAN.md D32).
  public static let hostNotTurnedOn = SessionProblem(
    message: "This session's host is no longer turned on in muxFinder, so nothing was opened. "
      + "Turn it on in Settings, then try again.",
    recoveries: [.openSettings, .retry])

  // MARK: - Detach

  /// The problem a "Detach from this Mac" that ended `result` shows; `nil` when it detached.
  public static func detach(_ result: SessionDetachResult) -> SessionProblem? {
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
  } // End of static func detach(_:)

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
