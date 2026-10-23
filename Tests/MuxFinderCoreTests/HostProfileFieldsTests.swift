import Foundation
import Testing

@testable import MuxFinderCore

/// The persistent-profile fields of the host list (PLAN.md D26): files written before they
/// existed load and save back unchanged, the new fields round-trip, and the invariants refuse
/// unusable values. Private temporary folders only; synthetic hosts.
@Suite("Host list persistent-profile fields")
struct HostProfileFieldsTests {
  /// A schema 1 file exactly as earlier builds wrote it (sorted keys, pretty-printed, a final
  /// newline): This Mac, an SSH host with an override and a profile, and a disabled draft.
  static let olderFile = """
    {
      "hosts" : [
        {
          "displayName" : "Local test",
          "id" : "11111111-1111-4111-8111-111111111111",
          "isEnabled" : true,
          "mode" : "local",
          "sshDestination" : ""
        },
        {
          "displayName" : "Remote test",
          "iTermProfileName" : "Test profile ü 日本",
          "id" : "22222222-2222-4222-8222-222222222222",
          "isEnabled" : true,
          "mode" : "ssh",
          "sshDestination" : "tester@remote.example.test",
          "tmuxPathOverride" : "/opt/test/bin/tmux"
        },
        {
          "displayName" : "Draft",
          "id" : "33333333-3333-4333-8333-333333333333",
          "isEnabled" : false,
          "mode" : "ssh",
          "sshDestination" : ""
        }
      ],
      "schemaVersion" : 1
    }

    """

  /// A store over `<base>/muxFinder/hosts.json` in a new private folder, with the folder made.
  static func makeStore() throws -> (store: HostStore, base: URL, file: URL) {
    let base = try TestSupport.makeTemporaryDirectory()
    let directory = base.appending(path: "muxFinder", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let file = directory.appending(path: HostStore.fileName)
    return (HostStore(fileURL: file), base, file)
  }

  /// Writes `text` as the store's file, mode 0600.
  static func write(_ text: String, to file: URL) throws {
    try Data(text.utf8).write(to: file)
    try #require(chmod(file.path(percentEncoded: false), 0o600) == 0)
  }

  /// An older file loads with the defaults (no profile, `main`, no parent), and saving the
  /// loaded list writes it back byte for byte.
  @Test func olderFilesLoadAndSaveUnchanged() async throws {
    let (store, base, file) = try Self.makeStore()
    defer { try? FileManager.default.removeItem(at: base) }
    try Self.write(Self.olderFile, to: file)
    let loaded = try await store.load()
    #expect(loaded.state == .saved)
    #expect(loaded.hosts.hosts.count == 3)
    for host in loaded.hosts.hosts {
      #expect(!host.persistentProfileEnabled)
      #expect(host.defaultSessionName == nil)
      #expect(host.persistentProfileParentName == nil)
      #expect(host.effectiveDefaultSessionName == "main")
    }
    try await store.save(loaded.hosts)
    #expect(try Data(contentsOf: file) == Data(Self.olderFile.utf8))
  } // End of func olderFilesLoadAndSaveUnchanged()

  /// Set fields are written under their names (the opt-in only when on), load back equal, and
  /// a second save writes the same bytes.
  @Test func newFieldsRoundTrip() async throws {
    let (store, base, file) = try Self.makeStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let list = try HostList([
      HostConfig(
        displayName: "Local test", mode: .local, persistentProfileEnabled: true,
        defaultSessionName: "work #1 ü;", persistentProfileParentName: "Base profile 日本"),
      HostConfig(
        displayName: "Remote test", mode: .ssh, sshDestination: "remote.example.test",
        persistentProfileEnabled: true),
      HostConfig(
        displayName: "Off", mode: .ssh, sshDestination: "", isEnabled: false,
        defaultSessionName: "kept"),
    ])
    try await store.save(list)
    let written = try Data(contentsOf: file)
    let loaded = try await store.load()
    #expect(loaded.state == .saved)
    #expect(loaded.hosts == list)
    let object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
    let hosts = try #require(object["hosts"] as? [[String: Any]])
    #expect(hosts[0]["persistentProfileEnabled"] as? Bool == true)
    #expect(hosts[0]["defaultSessionName"] as? String == "work #1 ü;")
    #expect(hosts[0]["persistentProfileParentName"] as? String == "Base profile 日本")
    #expect(Set(hosts[1].keys).contains("persistentProfileEnabled"))
    #expect(!Set(hosts[1].keys).contains("defaultSessionName"))
    #expect(
      Set(hosts[2].keys) == [
        "id", "displayName", "mode", "sshDestination", "isEnabled", "defaultSessionName",
      ])
    try await store.save(loaded.hosts)
    #expect(try Data(contentsOf: file) == written)
  } // End of func newFieldsRoundTrip()

  /// `persistentProfileEnabled: false` and `null` optional values read as the defaults; a
  /// field of the wrong type makes the file malformed.
  @Test func explicitDefaultsAndWrongTypes() async throws {
    let (store, base, file) = try Self.makeStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let host = """
      {"id": "44444444-4444-4444-8444-444444444444", "displayName": "X", "mode": "local",
       "sshDestination": "", "isEnabled": true, "persistentProfileEnabled": false,
       "defaultSessionName": null, "persistentProfileParentName": null}
      """
    try Self.write(#"{"schemaVersion": 1, "hosts": [\#(host)]}"#, to: file)
    let loaded = try await store.load()
    #expect(loaded.state == .saved)
    #expect(loaded.hosts.hosts.first?.persistentProfileEnabled == false)
    #expect(loaded.hosts.hosts.first?.defaultSessionName == nil)

    let wrong = host.replacingOccurrences(
      of: #""persistentProfileEnabled": false"#, with: #""persistentProfileEnabled": "yes""#)
    try Self.write(#"{"schemaVersion": 1, "hosts": [\#(wrong)]}"#, to: file)
    #expect(try await store.load().state == .invalid(.malformed))
  } // End of func explicitDefaultsAndWrongTypes()

  /// Default session names: `Validation.persistentSessionName`'s rules, stored trimmed, checked
  /// whether or not the profile is on. A file breaking them is `invariantBroken`, left as is.
  @Test(arguments: [
    ("", ValidationError.sessionNameEmpty),
    ("a:b", .sessionNameContainsColonOrPeriod),
    ("-x", .sessionNameStartsWithHyphen),
    ("$1", .sessionNameStartsWithTargetCharacter),
    ("=main", .sessionNameStartsWithTargetCharacter),
    ("{marked}", .sessionNameStartsWithTargetCharacter),
    (" main", .sessionNameNotTrimmed),
    ("main\n", .sessionNameNotTrimmed),
    ("a\tb", .sessionNameContainsControlCharacter),
  ])
  func refusesUnusableDefaultSessionNames(name: String, reason: ValidationError) async throws {
    let id = UUID()
    let host = HostConfig(
      id: id, displayName: "Local test", mode: .local, defaultSessionName: name)
    #expect(throws: HostListError.invalidDefaultSessionName(hostID: id, reason: reason)) {
      try HostList([host])
    }
    var list = try HostList([HostConfig(id: id, displayName: "Local test", mode: .local)])
    #expect(throws: HostListError.self) { try list.update(host) }
    #expect(list.hosts.first?.defaultSessionName == nil)

    let (store, base, file) = try Self.makeStore()
    defer { try? FileManager.default.removeItem(at: base) }
    try Self.write(
      String(decoding: try HostStore.encode(HostList(unchecked: [host])), as: UTF8.self), to: file)
    let before = try Data(contentsOf: file)
    let loaded = try await store.load()
    #expect(
      loaded.state
        == .invalid(.invariantBroken(.invalidDefaultSessionName(hostID: id, reason: reason))))
    #expect(try Data(contentsOf: file) == before)
  } // End of func refusesUnusableDefaultSessionNames(name:reason:)

  /// Parent profile names: not empty, no control characters; anything else (Unicode, spaces
  /// inside) is kept as typed.
  @Test func validatesParentProfileNames() throws {
    let id = UUID()
    for (name, reason) in [
      ("", ValidationError.profileNameEmpty), ("a\nb", .profileNameContainsControlCharacter),
    ] {
      #expect(throws: HostListError.invalidParentProfileName(hostID: id, reason: reason)) {
        try HostList([
          HostConfig(
            id: id, displayName: "X", mode: .local, persistentProfileParentName: name)
        ])
      }
    }
    let kept = try HostList([
      HostConfig(
        id: id, displayName: "X", mode: .local, persistentProfileParentName: " Base ü 日本 ")
    ])
    #expect(kept.hosts.first?.persistentProfileParentName == " Base ü 日本 ")
  } // End of func validatesParentProfileNames()

  /// Valid names, including Unicode, `#` and a trailing `;`, pass and are kept exactly.
  @Test(arguments: ["main", "work #1", "日本 ü", "x;", "a-b_c"])
  func acceptsUsableDefaultSessionNames(name: String) throws {
    let list = try HostList([
      HostConfig(displayName: "X", mode: .local, defaultSessionName: name)
    ])
    #expect(list.hosts.first?.effectiveDefaultSessionName == name)
    #expect(try Validation.persistentSessionName(name) == name)
  }
}
