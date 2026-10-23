import Foundation

/// One configured host: a Mac whose default tmux server muxFinder discovers.
///
/// This is the model only. The list rules (unique ids, at most one This Mac, a valid destination
/// for an enabled SSH host, valid persistent-profile values) belong to `HostList`, and
/// persistence (`hosts.json`) to `HostStore` (PLAN.md D19). Values the user types are stored as
/// typed and validated when they are used (`Validation`), so an incomplete entry, such as an
/// onboarding example with an empty destination, can still be saved while it is disabled.
///
/// The persistent-profile fields (PLAN.md D26) are written to `hosts.json` only when set
/// (`persistentProfileEnabled` only when `true`), and a file without them loads with the
/// defaults, so a list saved before they existed reads, and saves again, byte for byte as before.
public struct HostConfig: Sendable, Hashable, Codable, Identifiable {
  /// How muxFinder reaches the host's tmux server.
  public enum ConnectionMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// The Mac muxFinder runs on ("This Mac"). Discovery runs tmux directly, never through SSH.
    case local
    /// A remote Mac reached with `/usr/bin/ssh`, using the user's own SSH configuration.
    case ssh
  }

  /// The default session name of a persistent profile whose host sets none (PLAN.md D26).
  public static let standardDefaultSessionName = "main"

  /// Stable identity of the host. Part of every `SessionKey` discovered on it.
  public var id: UUID
  /// The name shown in the UI, for example "Saturno".
  public var displayName: String
  /// Local or SSH.
  public var mode: ConnectionMode
  /// The SSH destination (a host name, `user@host` or an `~/.ssh/config` alias). Ignored for
  /// local hosts; may be empty while the host is not set up yet.
  public var sshDestination: String
  /// An explicit tmux executable path. When set, discovery uses only this path (PLAN.md D5).
  public var tmuxPathOverride: String?
  /// The iTerm2 profile used for tabs opened for this host, or `nil` for iTerm2's default.
  public var iTermProfileName: String?
  /// Whether the host takes part in discovery.
  public var isEnabled: Bool
  /// Whether muxFinder's dynamic profile file holds a "Persistent work" profile for this host
  /// (PLAN.md D26). Independent of `isEnabled`: the profile is the user's explicit choice.
  public var persistentProfileEnabled: Bool
  /// The tmux session the persistent profile attaches or creates (`new-session -A -s`), or
  /// `nil` for `standardDefaultSessionName`. When set it passes
  /// `Validation.persistentSessionName(_:)` unchanged (a `HostList` invariant).
  public var defaultSessionName: String?
  /// The iTerm2 profile the persistent profile inherits from (`Dynamic Profile Parent Name`),
  /// or `nil` for iTerm2's default profile. When set it passes `Validation.profileName(_:)` (a
  /// `HostList` invariant).
  public var persistentProfileParentName: String?

  /// Creates a host configuration.
  public init(
    id: UUID = UUID(),
    displayName: String,
    mode: ConnectionMode,
    sshDestination: String = "",
    tmuxPathOverride: String? = nil,
    iTermProfileName: String? = nil,
    isEnabled: Bool = true,
    persistentProfileEnabled: Bool = false,
    defaultSessionName: String? = nil,
    persistentProfileParentName: String? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.mode = mode
    self.sshDestination = sshDestination
    self.tmuxPathOverride = tmuxPathOverride
    self.iTermProfileName = iTermProfileName
    self.isEnabled = isEnabled
    self.persistentProfileEnabled = persistentProfileEnabled
    self.defaultSessionName = defaultSessionName
    self.persistentProfileParentName = persistentProfileParentName
  } // End of init(id:displayName:mode:sshDestination:tmuxPathOverride:iTermProfileName:…)

  /// Whether this entry is "This Mac" (the local host).
  public var isThisMac: Bool { mode == .local }

  /// The session the persistent profile attaches or creates: `defaultSessionName`, or
  /// `standardDefaultSessionName` when none is set.
  public var effectiveDefaultSessionName: String {
    defaultSessionName ?? Self.standardDefaultSessionName
  }

  /// The JSON keys, the property names.
  private enum CodingKeys: String, CodingKey {
    /// `id`.
    case id
    /// `displayName`.
    case displayName
    /// `mode`.
    case mode
    /// `sshDestination`.
    case sshDestination
    /// `tmuxPathOverride`, only when set.
    case tmuxPathOverride
    /// `iTermProfileName`, only when set.
    case iTermProfileName
    /// `isEnabled`.
    case isEnabled
    /// `persistentProfileEnabled`, only when `true`.
    case persistentProfileEnabled
    /// `defaultSessionName`, only when set.
    case defaultSessionName
    /// `persistentProfileParentName`, only when set.
    case persistentProfileParentName
  }

  /// Decodes a host: `id`, `displayName`, `mode`, `sshDestination` and `isEnabled` are
  /// required, as they always were; the optional fields may be absent or `null`, and
  /// `persistentProfileEnabled` reads as `false` when absent. A field of the wrong type is a
  /// decoding error (the store reports the file as malformed).
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    displayName = try container.decode(String.self, forKey: .displayName)
    mode = try container.decode(ConnectionMode.self, forKey: .mode)
    sshDestination = try container.decode(String.self, forKey: .sshDestination)
    tmuxPathOverride = try container.decodeIfPresent(String.self, forKey: .tmuxPathOverride)
    iTermProfileName = try container.decodeIfPresent(String.self, forKey: .iTermProfileName)
    isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
    persistentProfileEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .persistentProfileEnabled) ?? false
    defaultSessionName = try container.decodeIfPresent(String.self, forKey: .defaultSessionName)
    persistentProfileParentName = try container.decodeIfPresent(
      String.self, forKey: .persistentProfileParentName)
  } // End of init(from:)

  /// Encodes the host as `hosts.json` stores it: the five fields every host has, the optional
  /// ones only when set, and `persistentProfileEnabled` only when `true`.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(displayName, forKey: .displayName)
    try container.encode(mode, forKey: .mode)
    try container.encode(sshDestination, forKey: .sshDestination)
    try container.encodeIfPresent(tmuxPathOverride, forKey: .tmuxPathOverride)
    try container.encodeIfPresent(iTermProfileName, forKey: .iTermProfileName)
    try container.encode(isEnabled, forKey: .isEnabled)
    if persistentProfileEnabled {
      try container.encode(true, forKey: .persistentProfileEnabled)
    }
    try container.encodeIfPresent(defaultSessionName, forKey: .defaultSessionName)
    try container.encodeIfPresent(
      persistentProfileParentName, forKey: .persistentProfileParentName)
  } // End of func encode(to:)
}
