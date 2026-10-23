import Foundation
import MuxFinderCore

/// What the last install, removal or automatic update of muxFinder's profile file did, and
/// what started it (PLAN.md D26).
public struct PersistentProfileResult: Sendable, Hashable {
  /// What started the change.
  public enum Trigger: String, Sendable, Hashable {
    /// "Install profiles" or "Remove profiles".
    case user
    /// A Settings save while muxFinder's file was installed.
    case save
    /// The check when muxFinder started.
    case launch
  }

  /// What was done.
  public var change: PersistentProfileChange
  /// What started it.
  public var trigger: Trigger

  /// Creates a result.
  public init(_ change: PersistentProfileChange, trigger: Trigger) {
    self.change = change
    self.trigger = trigger
  }

  /// The line shown under the buttons, or `nil` when there is nothing worth saying (an
  /// automatic update that changed nothing).
  public var text: String? {
    switch (change, trigger) {
    case (.installed(let count), .user):
      return count == 1
        ? "Installed 1 profile in iTerm2." : "Installed \(count) profiles in iTerm2."
    case (.unchanged, .user):
      return "The profiles in iTerm2 were already up to date."
    case (.removed, .user):
      return "Removed muxFinder's profiles from iTerm2."
    case (.nothingToRemove, .user):
      return "No muxFinder profiles were installed."
    case (.installed, .save):
      return "Updated the profiles in iTerm2 to match the saved hosts."
    case (.removed, .save):
      return "No saved host has a persistent profile any more, so muxFinder removed its profiles "
        + "from iTerm2."
    case (.installed, .launch):
      return "muxFinder updated its profiles in iTerm2 when it started, because they were out of "
        + "date."
    case (.removed, .launch):
      return "muxFinder removed its profiles from iTerm2 when it started, because no saved host "
        + "has a persistent profile any more."
    case (.unchanged, _), (.nothingToRemove, _), (.notInstalled, _):
      return nil
    case (.failed(let problem), .user):
      return problem.message
    case (.failed(let problem), .save):
      return "muxFinder couldn't update its profiles in iTerm2 after saving. " + problem.message
    case (.failed(let problem), .launch):
      return "muxFinder couldn't update its profiles in iTerm2 when it started. " + problem.message
    }
  } // End of var text

  /// Whether the line reports a failure.
  public var isProblem: Bool { change.isFailure }
}

/// What the Persistent profiles tab shows (PLAN.md D26): the file's status, the profiles the
/// saved hosts make, which buttons work and why not, and the last result. A pure value, so every
/// rule is tested without SwiftUI.
public struct PersistentProfilesContent: Sendable, Hashable {
  /// How the status line looks.
  public enum Tone: String, Sendable, Hashable {
    /// Not checked yet.
    case checking
    /// Nothing installed.
    case neutral
    /// Installed and up to date.
    case good
    /// Installed but out of date.
    case warning
    /// Unavailable.
    case problem
  }

  /// The status line.
  public var statusText: String
  /// How it looks.
  public var tone: Tone
  /// The names of the profiles the saved hosts make, in host-list order.
  public var profileNames: [String]
  /// Whether "Install profiles" works.
  public var canInstall: Bool
  /// Why it doesn't, when that is not already the status line's reason.
  public var installNote: String?
  /// Whether "Remove profiles" works.
  public var canRemove: Bool
  /// Whether "Check again" works.
  public var canCheck: Bool
  /// The note shown while the host editor holds unsaved changes.
  public var draftNote: String?
  /// Whether an install, a removal or a check runs.
  public var isRunning: Bool
  /// The last result's line, if any.
  public var resultText: String?
  /// Whether that line reports a failure.
  public var resultIsProblem: Bool

  /// The note shown while the host editor holds unsaved changes (PLAN.md D26: installs use the
  /// saved host list).
  public static let draftNoteText =
    "Install profiles uses the saved host list. Changes not saved yet in the Hosts tab are "
    + "left out until you save them."
  /// Why "Install profiles" is off while no saved host has its persistent profile on.
  public static let noProfilesNote =
    "Turn on “Persistent profile” for a host in the Hosts tab and save it, then install the "
    + "profiles."
  /// Why "Install profiles" is off while the host list is not saved or not usable.
  public static let listNotSavedNote =
    "Install profiles works from a saved host list. Save the host list in the Hosts tab first."
  /// Why "Install profiles" is off while the status is unavailable.
  public static let unavailableNote =
    "Install profiles is off until the problem above is solved. Choose Check again afterwards."

  /// The content for `status` (`nil`: not checked yet) of the saved `hosts`. `isListSaved` is
  /// whether `hosts` is the saved, usable host list (installs use only that); `isDirty` whether
  /// the host editor holds unsaved changes; `isRunning` whether an operation runs.
  public init(
    status: PersistentProfileStatus?,
    hosts: HostList,
    isListSaved: Bool,
    isDirty: Bool,
    isRunning: Bool,
    result: PersistentProfileResult?
  ) {
    profileNames =
      isListSaved
      ? hosts.hosts.filter(\.persistentProfileEnabled).map(PersistentProfiles.name(for:)) : []
    self.isRunning = isRunning
    switch status {
    case nil:
      statusText = "Checking muxFinder's profiles in iTerm2…"
      tone = .checking
    case .notInstalled:
      statusText = "Not installed."
      tone = .neutral
    case .current:
      statusText = "Installed and up to date."
      tone = .good
    case .stale:
      statusText =
        isListSaved
        ? "Installed, but out of date. Install profiles to update them." : "Installed."
      tone = isListSaved ? .warning : .neutral
    case .unavailable(let problem, let isInstalled):
      statusText =
        "Unavailable. " + problem.message
        + (isInstalled ? " The profiles installed before stay as they are." : "")
      tone = .problem
    }
    let isUnavailable: Bool
    if case .unavailable = status { isUnavailable = true } else { isUnavailable = false }
    if !isListSaved {
      installNote = Self.listNotSavedNote
    } else if profileNames.isEmpty {
      installNote = Self.noProfilesNote
    } else if isUnavailable {
      installNote = Self.unavailableNote
    } else {
      installNote = nil
    }
    canInstall = !isRunning && status != nil && installNote == nil
    canRemove = !isRunning && status?.isInstalled == true
    canCheck = !isRunning
    draftNote = isDirty && isListSaved ? Self.draftNoteText : nil
    resultText = result?.text
    resultIsProblem = result?.isProblem ?? false
  } // End of init(status:hosts:isListSaved:isDirty:isRunning:result:)
}
