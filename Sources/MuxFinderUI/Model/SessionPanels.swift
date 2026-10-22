import Foundation
import MuxFinderCore

/// What the popover shows in place of its host list while the user decides (PLAN.md D25): the
/// Move here confirmation or the New session sheet. Both are drawn inside the popover, so they
/// never leave the menu bar window and render in the preview fixtures.
public enum PopoverPanel: Sendable, Hashable {
  /// "Move here…": the confirmation in front of `AttachCoordinator.moveHere(_:confirmation:)`.
  case moveHere(MoveHereRequest)
  /// "New session": host, name, optional directory (`AppModel.newSessionDraft`).
  case newSession
}

/// The session a "Move here…" confirmation is about.
public struct MoveHereRequest: Sendable, Hashable {
  /// The session as the popover listed it, on its host.
  public var target: AttachTarget

  /// Creates a request.
  public init(target: AttachTarget) {
    self.target = target
  }

  /// The session's name.
  public var sessionName: String { target.session.name }
  /// The host's display name.
  public var hostName: String { target.host.displayName }

  /// The dialog's title.
  public var title: String { "Move “\(sessionName)” here?" }

  /// The dialog's explanation: what moving does, and what it leaves running.
  public var explanation: String {
    "muxFinder will open this session from \(hostName) in iTerm2 on this Mac and disconnect "
      + "every other client attached to it, including iTerm2 on your other Macs. Nothing is "
      + "closed: the session keeps running, and the other Macs can attach again later."
  }

  /// How many clients tmux reported attached when the session was listed, said plainly.
  public var clientsText: String {
    switch target.session.attachedClientCount {
    case 0: return "No client was attached when muxFinder last looked."
    case 1: return "1 client was attached when muxFinder last looked."
    case let count: return "\(count) clients were attached when muxFinder last looked."
    }
  }

  /// The confirming button's title.
  public static let confirmTitle = "Move here"
}

/// The New session sheet's fields and state (PLAN.md D18, D25). The name and the directory are
/// checked inline with the core's rules (`Validation.sessionName(_:)`,
/// `Validation.workingDirectory(_:)`); tmux decides collisions when the session is created.
public struct NewSessionDraft: Sendable, Hashable {
  /// Where the sheet is.
  public enum State: Sendable, Hashable {
    /// The user edits the fields.
    case editing
    /// The session is being created and attached.
    case creating
    /// A session with this name exists on the host; the sheet offers "Open existing".
    case collision
    /// "Open existing" lists the host's sessions afresh to find the one with this exact name.
    case findingExisting
    /// Creation failed; the message says why.
    case failed(String)
  }

  /// The host, by id (one of the enabled hosts).
  public var hostID: UUID? {
    didSet { if hostID != oldValue { editedAfterResult() } }
  }
  /// The name as typed.
  public var name = "" {
    didSet { if name != oldValue { editedAfterResult() } }
  }
  /// The working directory as typed; empty means the home folder on the host.
  public var directory = "" {
    didSet { if directory != oldValue { editedAfterResult() } }
  }
  /// Where the sheet is.
  public var state = State.editing
  /// Whether "Create" was pressed once, so an empty name is reported too.
  public var showsIssues = false

  /// A draft for `hostID`, empty otherwise.
  public init(hostID: UUID? = nil, name: String = "", directory: String = "") {
    self.hostID = hostID
    self.name = name
    self.directory = directory
  }

  /// Editing a field after a collision or a failure goes back to editing.
  private mutating func editedAfterResult() {
    switch state {
    case .collision, .failed: state = .editing
    default: break
    }
  }

  /// The name's problem, inline: any rule the typed name breaks, and once "Create" was pressed,
  /// an empty name too.
  public var nameIssue: String? {
    if name.isEmpty && !showsIssues { return nil }
    do throws(ValidationError) {
      _ = try Validation.sessionName(name)
      return nil
    } catch {
      return error.message
    }
  }

  /// The directory's problem, inline; an empty directory is fine (the home folder).
  public var directoryIssue: String? {
    guard !directory.isEmpty else { return nil }
    do throws(ValidationError) {
      _ = try Validation.workingDirectory(directory)
      return nil
    } catch {
      return error.message
    }
  }

  /// Whether the sheet is busy (creating, or looking for the existing session).
  public var isBusy: Bool { state == .creating || state == .findingExisting }

  /// The checked request for `hosts` (the enabled hosts), with `command` as the first pane's
  /// argv (empty: the user's shell), or `nil` while a field breaks a rule or no host is chosen.
  public func request(hosts: [HostConfig], command: [String] = []) -> NewSessionRequest? {
    guard let hostID, let host = hosts.first(where: { $0.id == hostID }),
      let name = try? Validation.sessionName(name)
    else { return nil }
    var workingDirectory: String?
    if !directory.isEmpty {
      guard let checked = try? Validation.workingDirectory(directory) else { return nil }
      workingDirectory = checked
    }
    return NewSessionRequest(
      host: host, name: name, workingDirectory: workingDirectory, command: command)
  } // End of func request(hosts:command:)

  /// The message shown for the sheet's state, if any.
  public var stateMessage: String? {
    switch state {
    case .editing: return nil
    case .creating: return "Creating the session and opening it in iTerm2…"
    case .collision: return SessionCreationError.sessionExists(.hasSession).message
    case .findingExisting: return "Looking for the existing session…"
    case .failed(let message): return message
    }
  }

  /// What "Open existing" shows when the host's fresh listing has no session with this exact
  /// name: the session tmux reported ended or was renamed meanwhile, so nothing was opened.
  public static let existingGone =
    "No session on this host has this name any more: it ended or was renamed after muxFinder "
    + "tried to create it, so nothing was opened. Check the list and try again."

  /// What "Open existing" shows when the host's sessions could not be listed afresh; `reason`
  /// (a sentence) says why. Nothing was opened.
  public static func existingNotListed(_ reason: String) -> String {
    "muxFinder could not list this host's sessions again to find the existing one, so nothing "
      + "was opened. " + reason
  }
}

/// One action on a session that ended, as `AppModel.finishedActions` records it (the self-tests
/// and the tests read it; the popover does not).
public struct SessionActionRecord: Sendable, Equatable {
  /// How it ended.
  public enum Outcome: Sendable, Equatable {
    /// Open (the row's default action).
    case attach(AttachResult)
    /// A confirmed "Move here…".
    case moveHere(AttachResult)
    /// "New session": creation, then the attach of the new session.
    case created(CreateAndAttachResult)
    /// "Detach from this Mac".
    case detached(SessionDetachResult)

    /// The attach result of an open, a move here or a creation, if any.
    public var attachResult: AttachResult? {
      switch self {
      case .attach(let result), .moveHere(let result): return result
      case .created(let result): return result.attach
      case .detached: return nil
      }
    }
  } // End of enum Outcome

  /// The session (for a creation, the created one; `nil` when creation failed).
  public var key: SessionKey?
  /// How it ended.
  public var outcome: Outcome
}

/// An attachment of a session in this Mac's iTerm2 that muxFinder made or found (a confirmed
/// or focused attach, or a move here's `alreadyAttachedHere`): what "Detach from this Mac" is
/// offered for besides the attachment index's badge, and what the self-tests print.
public struct AttachmentRecord: Sendable, Hashable {
  /// The tmux connection.
  public var connectionID: String
  /// The iTerm2 session that owns it (the launch tab running `tmux -CC`).
  public var gatewaySessionID: String
  /// The launch that made it, if muxFinder opened it.
  public var launchID: LaunchToken?
}
