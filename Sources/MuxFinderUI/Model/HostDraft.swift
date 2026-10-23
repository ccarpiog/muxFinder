import Foundation
import MuxFinderCore

/// The host editor's working copy of one host (PLAN.md D23): what the fields hold, as typed.
/// Nothing is saved until "Save"; `config` is what a save stores.
public struct HostDraft: Sendable, Hashable {
  /// The longest display name accepted, in characters.
  public static let maximumNameLength = 50

  /// The host's id (a new host's id is made when it is added).
  public var id: UUID
  /// Whether the host is not in the saved list yet ("Add host").
  public var isNew: Bool
  /// The display name field.
  public var displayName: String
  /// This Mac (`local`) or SSH.
  public var mode: HostConfig.ConnectionMode
  /// The SSH destination field.
  public var sshDestination: String
  /// The tmux path field; empty means automatic (PLAN.md D5).
  public var tmuxPath: String
  /// The iTerm2 profile field; empty means iTerm2's default profile.
  public var profileName: String
  /// Whether the host is turned on.
  public var isEnabled: Bool
  /// The persistent-profile fields (PLAN.md D26).
  public var persistentProfile: PersistentProfileSettings

  /// A host's persistent-profile fields as typed: the switch, the default session name (empty
  /// means `main`) and the parent profile (empty means none, so iTerm2's default profile).
  /// What a save stores: the session name trimmed, the parent trimmed, each empty as none; a
  /// parent field left exactly as loaded saves back the stored value unchanged, so a host's
  /// values round-trip whatever the file held.
  public struct PersistentProfileSettings: Sendable, Hashable {
    /// `HostConfig.persistentProfileEnabled`.
    public var isEnabled: Bool
    /// The default session name field.
    public var defaultSessionName: String
    /// The parent profile field.
    public var parentProfileName: String
    /// The parent as loaded (`nil`: none, or a new host).
    public let loadedParentName: String?

    /// The values of `host`.
    public init(_ host: HostConfig) {
      isEnabled = host.persistentProfileEnabled
      defaultSessionName = host.defaultSessionName ?? ""
      parentProfileName = host.persistentProfileParentName ?? ""
      loadedParentName = host.persistentProfileParentName
    }

    /// The trimmed session name field.
    public var trimmedSessionName: String {
      defaultSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The session name a save stores: trimmed, empty as none (`main`).
    public var storedSessionName: String? {
      trimmedSessionName.isEmpty ? nil : trimmedSessionName
    }

    /// The parent a save stores: the loaded value while the field is untouched, else the field
    /// trimmed, empty as none.
    public var storedParentName: String? {
      if parentProfileName == (loadedParentName ?? "") { return loadedParentName }
      let trimmed = parentProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
  } // End of struct PersistentProfileSettings

  /// The draft of a saved host.
  public init(_ host: HostConfig) {
    id = host.id
    isNew = false
    displayName = host.displayName
    mode = host.mode
    sshDestination = host.sshDestination
    tmuxPath = host.tmuxPathOverride ?? ""
    profileName = host.iTermProfileName ?? ""
    isEnabled = host.isEnabled
    persistentProfile = PersistentProfileSettings(host)
  }

  /// The draft of a host not added yet: SSH, no destination, turned off.
  public static func newHost(id: UUID = UUID()) -> HostDraft {
    var draft = HostDraft(
      HostConfig(id: id, displayName: "New host", mode: .ssh, sshDestination: "", isEnabled: false))
    draft.isNew = true
    return draft
  }

  /// The trimmed display name.
  public var trimmedName: String { displayName.trimmingCharacters(in: .whitespacesAndNewlines) }
  /// The trimmed SSH destination.
  public var trimmedDestination: String {
    sshDestination.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  /// The trimmed tmux path.
  public var trimmedTmuxPath: String { tmuxPath.trimmingCharacters(in: .whitespacesAndNewlines) }
  /// The trimmed profile name.
  public var trimmedProfileName: String {
    profileName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Whether the destination passes `Validation.sshDestination`.
  public var hasValidDestination: Bool {
    (try? Validation.sshDestination(trimmedDestination)) != nil
  }

  /// Whether the host may be turned on: This Mac always, an SSH host only with a valid
  /// destination (PLAN.md D19).
  public var canTurnOn: Bool { mode == .local || hasValidDestination }

  /// Whether "Detect" can run: This Mac, or an SSH host with a valid destination. The tmux path
  /// field is ignored (Detect looks for tmux without it).
  public var canDetect: Bool { mode == .local || hasValidDestination }

  /// Whether "Test connection" can run: as for Detect, and the tmux path is empty or valid.
  public var canTest: Bool {
    guard canDetect else { return false }
    return trimmedTmuxPath.isEmpty || (try? Validation.executablePath(trimmedTmuxPath)) != nil
  }

  /// The configuration this draft saves: trimmed values, an empty tmux path, profile, default
  /// session name or parent profile stored as none (see `PersistentProfileSettings`).
  public var config: HostConfig {
    HostConfig(
      id: id,
      displayName: trimmedName,
      mode: mode,
      sshDestination: trimmedDestination,
      tmuxPathOverride: trimmedTmuxPath.isEmpty ? nil : trimmedTmuxPath,
      iTermProfileName: trimmedProfileName.isEmpty ? nil : trimmedProfileName,
      isEnabled: isEnabled,
      persistentProfileEnabled: persistentProfile.isEnabled,
      defaultSessionName: persistentProfile.storedSessionName,
      persistentProfileParentName: persistentProfile.storedParentName)
  }

  /// The configuration a probe runs with: `config`, without the tmux path when `detecting`.
  public func probeConfig(detecting: Bool) -> HostConfig {
    var host = config
    if detecting { host.tmuxPathOverride = nil }
    return host
  }

  /// Whether the fields discovery uses (mode, destination, tmux path) differ from `other`'s.
  public func discoveryDiffers(from other: HostDraft) -> Bool {
    mode != other.mode || trimmedDestination != other.trimmedDestination
      || trimmedTmuxPath != other.trimmedTmuxPath
  }
}

/// The host editor's inline validation errors, one per field, English and sentence case. A
/// draft with any of them cannot be saved.
public struct HostDraftIssues: Sendable, Hashable {
  /// The display name's problem.
  public var displayName: String?
  /// The SSH destination's problem.
  public var destination: String?
  /// The tmux path's problem.
  public var tmuxPath: String?
  /// The profile name's problem.
  public var profileName: String?
  /// Why the host cannot be turned on as it is.
  public var enabled: String?
  /// The persistent profile's default session name's problem.
  public var defaultSessionName: String?
  /// The persistent profile's parent profile's problem.
  public var parentProfileName: String?

  /// The message for an SSH host turned on without a valid destination (PLAN.md D19).
  public static let destinationNeededToTurnOn =
    "An SSH host can't be turned on until it has a valid SSH destination."

  /// The rules, checked on `draft` among the other saved hosts (`otherHosts`, without the
  /// draft's own host):
  ///
  /// - **Name:** not empty, at most `HostDraft.maximumNameLength` characters, no control
  ///   characters, and not the name of another host (ignoring case and surrounding spaces).
  /// - **SSH destination** (SSH only): empty, or valid for `Validation.sshDestination` (no
  ///   spaces, control characters or leading "-"); required while the host is turned on.
  /// - **Turned on:** an SSH host needs a valid destination.
  /// - **tmux path:** empty (automatic) or a full path (`Validation.executablePath`).
  /// - **Profile:** no control characters.
  /// - **Persistent profile** (PLAN.md D26, checked whether or not it is on, as `HostList`
  ///   checks): the default session name empty (`main`) or, trimmed, valid for
  ///   `Validation.persistentSessionName`; the parent profile empty (none) or, as it would be
  ///   stored, valid for `Validation.profileName`.
  public init(draft: HostDraft, otherHosts: [HostConfig]) {
    let name = draft.trimmedName
    if name.isEmpty {
      displayName = "Enter a name for this host."
    } else if name.count > HostDraft.maximumNameLength {
      displayName = "Names can be at most \(HostDraft.maximumNameLength) characters long."
    } else if Self.containsControlCharacter(name) {
      displayName = "Names can't contain line breaks, tabs or other control characters."
    } else if otherHosts.contains(where: { Self.sameName($0.displayName, name) }) {
      displayName = "Another host already has this name."
    }
    if draft.mode == .ssh {
      let destination = draft.trimmedDestination
      if !destination.isEmpty || draft.isEnabled {
        do throws(ValidationError) {
          _ = try Validation.sshDestination(destination)
        } catch {
          self.destination = error.message
        }
      }
      if draft.isEnabled, !draft.hasValidDestination {
        enabled = Self.destinationNeededToTurnOn
      }
    }
    let path = draft.trimmedTmuxPath
    if !path.isEmpty {
      do throws(ValidationError) {
        _ = try Validation.executablePath(path)
      } catch {
        tmuxPath = error.message
      }
    }
    if Self.containsControlCharacter(draft.trimmedProfileName) {
      profileName = "Profile names can't contain control characters."
    }
    if let session = draft.persistentProfile.storedSessionName {
      do throws(ValidationError) {
        _ = try Validation.persistentSessionName(session)
      } catch {
        defaultSessionName = error.message
      }
    }
    if let parent = draft.persistentProfile.storedParentName {
      do throws(ValidationError) {
        _ = try Validation.profileName(parent)
      } catch {
        parentProfileName = error.message
      }
    }
  } // End of init(draft:otherHosts:)

  /// Whether the draft has no problem.
  public var isValid: Bool {
    displayName == nil && destination == nil && tmuxPath == nil && profileName == nil
      && enabled == nil && defaultSessionName == nil && parentProfileName == nil
  }

  /// Whether two display names are the same, ignoring case and surrounding spaces.
  static func sameName(_ first: String, _ second: String) -> Bool {
    first.trimmingCharacters(in: .whitespacesAndNewlines)
      .compare(second, options: [.caseInsensitive]) == .orderedSame
  }

  /// Whether `text` holds a Unicode control character (general category Cc).
  static func containsControlCharacter(_ text: String) -> Bool {
    text.unicodeScalars.contains { $0.properties.generalCategory == .control }
  }
}
