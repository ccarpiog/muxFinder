import Foundation

/// Why a host list, or a change to one, was refused. `message` is the English, sentence-case
/// text shown in the UI; it names no host, so it can also be logged.
public enum HostListError: Error, Sendable, Hashable, LocalizedError {
  /// Two hosts share this id.
  case duplicateID(UUID)
  /// More than one host is in local mode ("This Mac").
  case moreThanOneThisMac
  /// The enabled SSH host with this id has no valid destination (`Validation.sshDestination`).
  case sshDestinationRequired(hostID: UUID, reason: ValidationError)
  /// No host has this id.
  case unknownHost(UUID)
  /// The host with this id has a default session name that does not pass
  /// `Validation.persistentSessionName(_:)` exactly as stored (PLAN.md D26).
  case invalidDefaultSessionName(hostID: UUID, reason: ValidationError)
  /// The host with this id has a persistent profile parent name that does not pass
  /// `Validation.profileName(_:)` (PLAN.md D26).
  case invalidParentProfileName(hostID: UUID, reason: ValidationError)

  /// The user-facing explanation.
  public var message: String {
    switch self {
    case .duplicateID:
      return "Two hosts have the same identifier."
    case .moreThanOneThisMac:
      return "Only one host can be This Mac."
    case .sshDestinationRequired(_, let reason):
      return "An SSH host can't be turned on until it has a valid SSH destination. "
        + reason.message
    case .unknownHost:
      return "That host is no longer in the list."
    case .invalidDefaultSessionName(_, let reason):
      return "A host's default session name isn't usable. " + reason.message
    case .invalidParentProfileName(_, let reason):
      return "A host's parent profile name isn't usable. " + reason.message
    }
  } // End of var message

  /// `LocalizedError` conformance, so `localizedDescription` shows `message`.
  public var errorDescription: String? { message }
}

/// The configured hosts, in display order, always satisfying the host-list invariants
/// (PLAN.md D19):
///
/// - every id is unique;
/// - at most one host is in local mode, "This Mac";
/// - an enabled SSH host has a destination that passes `Validation.sshDestination`;
/// - a host's default session name, when set, passes `Validation.persistentSessionName`
///   exactly as stored (trimmed), and its persistent profile parent name, when set, passes
///   `Validation.profileName` (PLAN.md D26), whether or not its persistent profile is on.
///
/// A disabled SSH host may have any destination, so an incomplete entry (an onboarding example
/// with an empty destination) can be kept. Other values (the tmux override, the profile name)
/// are validated where they are used. Every mutation checks the result first and throws a
/// `HostListError` without changing anything when an invariant would break.
public struct HostList: Sendable, Hashable {
  /// The hosts, in display order.
  public private(set) var hosts: [HostConfig]

  /// An empty list.
  public init() {
    hosts = []
  }

  /// A list of `hosts`, refused if they break an invariant.
  public init(_ hosts: [HostConfig]) throws(HostListError) {
    try Self.validate(hosts)
    self.hosts = hosts
  }

  /// A list taken as it is, without checking it. Only for tests of the checks that follow it
  /// (such as `HostStore.save(_:)` refusing an invalid list).
  init(unchecked hosts: [HostConfig]) {
    self.hosts = hosts
  }

  /// The onboarding examples from the brief: Saturno, Neptuno and Sirio as SSH hosts with empty
  /// destinations, disabled, none of them This Mac. No user name, address or reachability is
  /// assumed. Each call gives fresh ids.
  public static func onboardingDefaults() -> HostList {
    HostList(
      unchecked: ["Saturno", "Neptuno", "Sirio"].map { name in
        HostConfig(displayName: name, mode: .ssh, sshDestination: "", isEnabled: false)
      }
    )
  }

  // MARK: - Reading

  /// The host in local mode, if one is chosen.
  public var thisMac: HostConfig? {
    hosts.first(where: \.isThisMac)
  }

  /// The hosts that take part in discovery.
  public var enabledHosts: [HostConfig] {
    hosts.filter(\.isEnabled)
  }

  /// The host with `id`, if any.
  public func host(withID id: UUID) -> HostConfig? {
    hosts.first { $0.id == id }
  }

  // MARK: - Invariants

  /// Checks the invariants on this list.
  public func validate() throws(HostListError) {
    try Self.validate(hosts)
  }

  /// Checks the invariants on `hosts`: unique ids, then at most one This Mac, then a valid
  /// destination for every enabled SSH host, then the persistent-profile values. Throws the
  /// first violation found.
  public static func validate(_ hosts: [HostConfig]) throws(HostListError) {
    var seen = Set<UUID>()
    for host in hosts where !seen.insert(host.id).inserted {
      throw .duplicateID(host.id)
    }
    guard hosts.filter(\.isThisMac).count <= 1 else { throw .moreThanOneThisMac }
    for host in hosts where host.mode == .ssh && host.isEnabled {
      do throws(ValidationError) {
        _ = try Validation.sshDestination(host.sshDestination)
      } catch {
        throw .sshDestinationRequired(hostID: host.id, reason: error)
      }
    } // End of loop over enabled SSH hosts
    for host in hosts {
      try validatePersistentProfile(of: host)
    }
  } // End of func validate(_:)

  /// Checks `host`'s persistent-profile values (PLAN.md D26): a set default session name must
  /// pass `Validation.persistentSessionName` and be stored trimmed (so the name the profile
  /// starts is exactly the stored one), and a set parent profile name must pass
  /// `Validation.profileName`.
  static func validatePersistentProfile(of host: HostConfig) throws(HostListError) {
    if let name = host.defaultSessionName {
      do throws(ValidationError) {
        guard try Validation.persistentSessionName(name) == name else {
          throw ValidationError.sessionNameNotTrimmed
        }
      } catch {
        throw .invalidDefaultSessionName(hostID: host.id, reason: error)
      }
    }
    if let parent = host.persistentProfileParentName {
      do throws(ValidationError) {
        _ = try Validation.profileName(parent)
      } catch {
        throw .invalidParentProfileName(hostID: host.id, reason: error)
      }
    }
  } // End of func validatePersistentProfile(of:)

  // MARK: - Changes

  /// Appends `host`.
  public mutating func add(_ host: HostConfig) throws(HostListError) {
    try replaceHosts(with: hosts + [host])
  }

  /// Replaces the host that has `host.id` with `host`, keeping its position.
  public mutating func update(_ host: HostConfig) throws(HostListError) {
    let position = try index(of: host.id)
    var candidate = hosts
    candidate[position] = host
    try replaceHosts(with: candidate)
  }

  /// Removes the host with `id` and returns it. Removing This Mac leaves the list without one.
  @discardableResult
  public mutating func remove(id: UUID) throws(HostListError) -> HostConfig {
    let position = try index(of: id)
    return hosts.remove(at: position)
  }

  /// Turns the host with `id` on or off. Turning on an SSH host without a valid destination
  /// throws `sshDestinationRequired`.
  public mutating func setEnabled(_ isEnabled: Bool, forHostWithID id: UUID) throws(HostListError) {
    let position = try index(of: id)
    var candidate = hosts
    candidate[position].isEnabled = isEnabled
    try replaceHosts(with: candidate)
  }

  /// Makes the host with `id` This Mac (the explicit "This Mac" choice).
  ///
  /// If it is This Mac already, nothing changes. Otherwise it becomes local and enabled (local
  /// discovery needs no destination), and the previous This Mac host, if any, goes back to SSH
  /// mode, disabled, its destination kept, so nothing starts connecting over SSH until the user
  /// turns it on again.
  public mutating func makeThisMac(id: UUID) throws(HostListError) {
    let position = try index(of: id)
    guard !hosts[position].isThisMac else { return }
    var candidate = hosts
    for other in candidate.indices where candidate[other].isThisMac {
      candidate[other].mode = .ssh
      candidate[other].isEnabled = false
    }
    candidate[position].mode = .local
    candidate[position].isEnabled = true
    try replaceHosts(with: candidate)
  } // End of func makeThisMac(id:)

  /// The position of the host with `id`, or `unknownHost`.
  func index(of id: UUID) throws(HostListError) -> Int {
    guard let index = hosts.firstIndex(where: { $0.id == id }) else { throw .unknownHost(id) }
    return index
  }

  /// Checks `candidate` and makes it the list.
  mutating func replaceHosts(with candidate: [HostConfig]) throws(HostListError) {
    try Self.validate(candidate)
    hosts = candidate
  }
}
