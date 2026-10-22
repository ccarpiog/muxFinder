import Foundation
import Testing

@testable import MuxFinderCore

/// Tests for `HostList`: the onboarding defaults, the invariants and every change. Host names
/// and destinations are synthetic.
@Suite("Host list")
struct HostListTests {
  /// An SSH host with a valid destination, enabled.
  static func configuredHost(_ name: String = "Alpha") -> HostConfig {
    HostConfig(displayName: name, mode: .ssh, sshDestination: "alpha.example.test")
  }

  /// The defaults are exactly Saturno, Neptuno and Sirio, in that order: SSH, empty
  /// destination, disabled, no override or profile, unique ids, none of them This Mac.
  @Test func onboardingDefaults() throws {
    let list = HostList.onboardingDefaults()
    #expect(list.hosts.map(\.displayName) == ["Saturno", "Neptuno", "Sirio"])
    for host in list.hosts {
      #expect(host.mode == .ssh)
      #expect(host.sshDestination == "")
      #expect(!host.isEnabled)
      #expect(host.tmuxPathOverride == nil)
      #expect(host.iTermProfileName == nil)
    }
    #expect(Set(list.hosts.map(\.id)).count == 3)
    #expect(list.thisMac == nil)
    #expect(list.enabledHosts.isEmpty)
    try list.validate()
    #expect(try HostList(list.hosts) == list)
  } // End of func onboardingDefaults()

  /// Making a host This Mac turns it local and on; switching to another host turns the
  /// previous one back into a disabled SSH host that keeps its destination. Repeating the
  /// switch changes nothing.
  @Test func switchesThisMac() throws {
    var list = HostList.onboardingDefaults()
    let saturno = list.hosts[0].id
    let neptuno = list.hosts[1].id
    var withDestination = try #require(list.host(withID: neptuno))
    withDestination.sshDestination = "neptuno.example.test"
    try list.update(withDestination)

    try list.makeThisMac(id: neptuno)
    #expect(list.thisMac?.id == neptuno)
    #expect(list.host(withID: neptuno)?.mode == .local)
    #expect(list.host(withID: neptuno)?.isEnabled == true)
    let once = list
    try list.makeThisMac(id: neptuno)
    #expect(list == once)

    try list.makeThisMac(id: saturno)
    #expect(list.thisMac?.id == saturno)
    #expect(list.host(withID: saturno)?.mode == .local)
    #expect(list.host(withID: saturno)?.isEnabled == true)
    let previous = try #require(list.host(withID: neptuno))
    #expect(previous.mode == .ssh)
    #expect(!previous.isEnabled)
    #expect(previous.sshDestination == "neptuno.example.test")
    #expect(list.hosts.filter(\.isThisMac).count == 1)
    #expect(list.hosts.map(\.displayName) == ["Saturno", "Neptuno", "Sirio"])

    let before = list
    let unknown = UUID()
    #expect(throws: HostListError.unknownHost(unknown)) { try list.makeThisMac(id: unknown) }
    #expect(list == before)
  } // End of func switchesThisMac()

  /// An SSH host whose destination is empty or fails `Validation.sshDestination` cannot be
  /// turned on, by `setEnabled`, `update` or `add`; the list stays as it was. Once the
  /// destination is valid it can.
  @Test func refusesToEnableAnIncompleteSSHHost() throws {
    var list = HostList.onboardingDefaults()
    let id = list.hosts[0].id
    let before = list
    #expect(
      throws: HostListError.sshDestinationRequired(hostID: id, reason: .sshDestinationEmpty)
    ) { try list.setEnabled(true, forHostWithID: id) }
    #expect(list == before)

    let invalid: [(String, ValidationError)] = [
      ("with space", .sshDestinationContainsWhitespace),
      ("-oProxyCommand=x", .sshDestinationStartsWithHyphen),
      ("line\nbreak", .sshDestinationContainsControlCharacter),
      ("tab\tseparated", .sshDestinationContainsControlCharacter),
      ("bell\u{07}", .sshDestinationContainsControlCharacter),
    ]
    for (destination, reason) in invalid {
      var host = try #require(list.host(withID: id))
      host.sshDestination = destination
      host.isEnabled = true
      #expect(throws: HostListError.sshDestinationRequired(hostID: id, reason: reason)) {
        try list.update(host)
      }
      #expect(list == before)
      host.id = UUID()
      #expect(throws: HostListError.sshDestinationRequired(hostID: host.id, reason: reason)) {
        try list.add(host)
      }
      #expect(list == before)
    } // End of loop over invalid destinations

    // Disabled, an incomplete entry can still be stored.
    var draft = try #require(list.host(withID: id))
    draft.sshDestination = "with space"
    try list.update(draft)
    #expect(list.host(withID: id)?.sshDestination == "with space")

    draft.sshDestination = "user@saturno.example.test"
    try list.update(draft)
    try list.setEnabled(true, forHostWithID: id)
    #expect(list.host(withID: id)?.isEnabled == true)
    #expect(list.enabledHosts.map(\.id) == [id])
  } // End of func refusesToEnableAnIncompleteSSHHost()

  /// A local host needs no destination to be enabled, and a disabled SSH host may have none.
  @Test func localHostsNeedNoDestination() throws {
    let local = HostConfig(displayName: "Here", mode: .local, isEnabled: true)
    let draft = HostConfig(displayName: "Later", mode: .ssh, isEnabled: false)
    let list = try HostList([local, draft])
    #expect(list.thisMac == local)
    #expect(list.enabledHosts == [local])
  }

  /// A list with two This Mac hosts or a repeated id is refused, at creation and by every
  /// change that would produce one.
  @Test func enforcesUniqueIDsAndOneThisMac() throws {
    let first = HostConfig(displayName: "One", mode: .local)
    let second = HostConfig(displayName: "Two", mode: .local)
    #expect(throws: HostListError.moreThanOneThisMac) { try HostList([first, second]) }
    let other = Self.configuredHost()
    var twin = Self.configuredHost("Twin")
    twin.id = other.id
    #expect(throws: HostListError.duplicateID(other.id)) { try HostList([other, twin]) }
    #expect(throws: HostListError.duplicateID(other.id)) {
      try HostList.validate([other, first, twin, second])
    }

    var list = try HostList([first, other])
    let before = list
    #expect(throws: HostListError.moreThanOneThisMac) { try list.add(second) }
    #expect(throws: HostListError.duplicateID(other.id)) { try list.add(twin) }
    var turnedLocal = other
    turnedLocal.mode = .local
    #expect(throws: HostListError.moreThanOneThisMac) { try list.update(turnedLocal) }
    #expect(list == before)
  } // End of func enforcesUniqueIDsAndOneThisMac()

  /// `add`, `update` and `remove` keep the order; unknown ids are reported; removing This Mac
  /// leaves none.
  @Test func addsUpdatesAndRemoves() throws {
    var list = HostList()
    let alpha = Self.configuredHost("Alpha")
    let local = HostConfig(displayName: "Here", mode: .local)
    try list.add(alpha)
    try list.add(local)
    #expect(list.hosts == [alpha, local])

    var renamed = alpha
    renamed.displayName = "Alpha renamed"
    renamed.tmuxPathOverride = "/opt/test/bin/tmux"
    renamed.iTermProfileName = "Test profile"
    try list.update(renamed)
    #expect(list.hosts == [renamed, local])

    let unknown = HostConfig(displayName: "Nobody", mode: .ssh)
    #expect(throws: HostListError.unknownHost(unknown.id)) { try list.update(unknown) }
    #expect(throws: HostListError.unknownHost(unknown.id)) { try list.remove(id: unknown.id) }
    #expect(throws: HostListError.unknownHost(unknown.id)) {
      try list.setEnabled(false, forHostWithID: unknown.id)
    }

    #expect(try list.remove(id: local.id) == local)
    #expect(list.thisMac == nil)
    #expect(list.hosts == [renamed])
  } // End of func addsUpdatesAndRemoves()

  /// Error messages are English, sentence case, and name no host.
  @Test func messagesNameNoHost() {
    let id = UUID()
    let errors: [HostListError] = [
      .duplicateID(id),
      .moreThanOneThisMac,
      .sshDestinationRequired(hostID: id, reason: .sshDestinationEmpty),
      .unknownHost(id),
    ]
    for error in errors {
      #expect(!error.message.isEmpty)
      #expect(!error.message.contains(id.uuidString))
      #expect(error.message.first?.isUppercase == true)
      #expect(error.localizedDescription == error.message)
    }
  } // End of func messagesNameNoHost()
}
