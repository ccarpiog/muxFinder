import Foundation

/// One configured host: a Mac whose default tmux server muxFinder discovers.
///
/// This is the model only. The list rules (unique ids, at most one This Mac, a valid destination
/// for an enabled SSH host) belong to `HostList`, and persistence (`hosts.json`) to `HostStore`
/// (PLAN.md D19). Values the user types are stored as typed and validated when they are used
/// (`Validation`), so an incomplete entry, such as an onboarding example with an empty
/// destination, can still be saved while it is disabled.
public struct HostConfig: Sendable, Hashable, Codable, Identifiable {
  /// How muxFinder reaches the host's tmux server.
  public enum ConnectionMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// The Mac muxFinder runs on ("This Mac"). Discovery runs tmux directly, never through SSH.
    case local
    /// A remote Mac reached with `/usr/bin/ssh`, using the user's own SSH configuration.
    case ssh
  }

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

  /// Creates a host configuration.
  public init(
    id: UUID = UUID(),
    displayName: String,
    mode: ConnectionMode,
    sshDestination: String = "",
    tmuxPathOverride: String? = nil,
    iTermProfileName: String? = nil,
    isEnabled: Bool = true
  ) {
    self.id = id
    self.displayName = displayName
    self.mode = mode
    self.sshDestination = sshDestination
    self.tmuxPathOverride = tmuxPathOverride
    self.iTermProfileName = iTermProfileName
    self.isEnabled = isEnabled
  } // End of init(id:displayName:mode:sshDestination:tmuxPathOverride:iTermProfileName:isEnabled:)

  /// Whether this entry is "This Mac" (the local host).
  public var isThisMac: Bool { mode == .local }
}
