import Foundation
import Testing

@testable import MuxFinderCore

/// The persistent profile generator (PLAN.md D26): golden documents for This Mac and an SSH
/// host, with and without a parent profile, the refusal of helper paths iTerm2 could split
/// wrongly, and the pure parts (GUIDs, names, command lines). Synthetic hosts only.
@Suite("Persistent profile generator")
struct PersistentProfilesTests {
  /// The app's helper in /Applications.
  static let helper = "/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch"
  /// This Mac's id.
  static let localID = UUID(uuidString: "0F8FAD5B-D9CB-469F-A165-70867728950E")!
  /// The SSH host's id.
  static let remoteID = UUID(uuidString: "7C9E6679-7425-40DE-944B-E07FC1F90AE7")!

  /// This Mac, opted in, with a tmux override (not part of the profile).
  static let local = HostConfig(
    id: localID, displayName: "This Mac", mode: .local, tmuxPathOverride: "/opt/test/bin/tmux",
    persistentProfileEnabled: true, defaultSessionName: "work")
  /// An SSH host, opted in but turned off for discovery, with an iTerm2 profile for launch
  /// tabs (not the parent).
  static let remote = HostConfig(
    id: remoteID, displayName: "Remote ü 日本", mode: .ssh, sshDestination: "remote.example.test",
    iTermProfileName: "Launch tabs", isEnabled: false, persistentProfileEnabled: true)
  /// A host without a profile.
  static let other = HostConfig(
    displayName: "Other", mode: .ssh, sshDestination: "other.example.test")

  /// The golden document `name` from `Fixtures/profiles/`.
  static func golden(_ name: String) throws -> String {
    String(decoding: try TestSupport.fixture("profiles/\(name).json"), as: UTF8.self)
  }

  /// This Mac and an SSH host, no parent: one profile each, in list order, the host without a
  /// profile left out; byte for byte the golden file, twice.
  @Test func localAndSSHGolden() throws {
    let list = try HostList([Self.local, Self.other, Self.remote])
    let document = try PersistentProfiles.document(for: list, helperPath: Self.helper)
    #expect(String(decoding: document.data, as: UTF8.self) == (try Self.golden("local-and-ssh")))
    #expect(
      document.profiles.map(\.guid) == [
        "muxfinder-persistent-0f8fad5b-d9cb-469f-a165-70867728950e",
        "muxfinder-persistent-7c9e6679-7425-40de-944b-e07fc1f90ae7",
      ])
    #expect(!document.isEmpty)
    #expect(try PersistentProfiles.document(for: list, helperPath: Self.helper) == document)
  } // End of func localAndSSHGolden()

  /// A parent profile name (with a quote and Unicode) is `Dynamic Profile Parent Name`, escaped
  /// as JSON; another valid helper location changes only the command.
  @Test func withParentGolden() throws {
    var remote = Self.remote
    remote.persistentProfileParentName = "Base \"profile\" ü"
    let document = try PersistentProfiles.document(
      for: try HostList([remote]),
      helperPath: "/Users/tester/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch")
    #expect(String(decoding: document.data, as: UTF8.self) == (try Self.golden("with-parent")))
  }

  /// The document parses as iTerm2 reads it: a `Profiles` array of objects whose values have
  /// the expected JSON types.
  @Test func documentHasITerm2Types() throws {
    var local = Self.local
    local.persistentProfileParentName = "Base"
    let document = try PersistentProfiles.document(
      for: try HostList([local]), helperPath: Self.helper)
    let root = try #require(
      try JSONSerialization.jsonObject(with: document.data) as? [String: Any])
    #expect(Array(root.keys) == ["Profiles"])
    let profile = try #require((root["Profiles"] as? [[String: Any]])?.first)
    #expect(profile["Close Sessions On End"] as? Bool == true)
    #expect(profile["Custom Command"] as? String == "Yes")
    #expect(profile["Tags"] as? [String] == ["muxFinder"])
    #expect(profile["Dynamic Profile Parent Name"] as? String == "Base")
    #expect(profile["Name"] as? String == "Persistent work \u{2013} This Mac")
    let command = try #require(profile["Command"] as? String)
    #expect(
      command.split(separator: " ").map(String.init)
        == [Self.helper, "profile", "0f8fad5b-d9cb-469f-a165-70867728950e"])
  } // End of func documentHasITerm2Types()

  /// No host with a profile: an empty document (installing it removes the file).
  @Test func noOptedInHostIsEmpty() throws {
    let document = try PersistentProfiles.document(
      for: try HostList([Self.other]), helperPath: Self.helper)
    #expect(document.isEmpty)
    let root = try #require(
      try JSONSerialization.jsonObject(with: document.data) as? [String: Any])
    #expect((root["Profiles"] as? [Any])?.isEmpty == true)
  }

  /// Helper paths iTerm2's command splitting could cut (spaces, quotes, `$`, non-ASCII,
  /// control characters) or that are not absolute are refused with D2's error.
  @Test(arguments: [
    (
      "/Applications/mux Finder.app/Contents/MacOS/muxfinder-launch",
      LaunchHelperPathError.unsupportedCharacters
    ),
    ("/Users/tester/Applications/muxFinder's.app/muxfinder-launch", .unsupportedCharacters),
    ("/tmp/$HOME/muxfinder-launch", .unsupportedCharacters),
    ("/Users/tëster/muxfinder-launch", .unsupportedCharacters),
    ("/tmp/a\tb/muxfinder-launch", .unsupportedCharacters),
    ("muxfinder-launch", .notAbsolute),
    ("", .notAbsolute),
  ])
  func refusesUnrepresentableHelperPaths(path: String, error: LaunchHelperPathError) throws {
    let list = try HostList([Self.local])
    #expect(throws: PersistentProfileError.unsupportedHelperPath(error)) {
      try PersistentProfiles.document(for: list, helperPath: path)
    }
    #expect(PersistentProfileError.unsupportedHelperPath(error).message == error.message)
  }

  /// GUIDs are `muxfinder-persistent-<lowercase id>` and read back; other GUIDs name no host.
  @Test func guidsRoundTrip() {
    let guid = PersistentProfiles.guid(forHostID: Self.remoteID)
    #expect(guid == "muxfinder-persistent-7c9e6679-7425-40de-944b-e07fc1f90ae7")
    #expect(PersistentProfiles.hostID(fromGUID: guid) == Self.remoteID)
    #expect(PersistentProfiles.hostID(fromGUID: guid.uppercased()) == nil)
    #expect(
      PersistentProfiles.hostID(
        fromGUID: "muxfinder-persistent-7C9E6679-7425-40DE-944B-E07FC1F90AE7") == nil)
    #expect(PersistentProfiles.hostID(fromGUID: "6F9619FF-8B86-D011-B42D-00C04FC964FF") == nil)
  }

  /// The command line is exactly three words, the third a canonical host id the helper parses
  /// as `profile <host id>`.
  @Test func commandLineParsesAsProfileMode() throws {
    let helper = try LaunchHelperPath(validating: Self.helper)
    let line = helper.profileCommandLine(forHostID: Self.localID)
    let words = line.split(separator: " ").map { Array($0.utf8) }
    #expect(words.count == 3)
    #expect(LaunchHelper.parse(words) == .profile(LaunchToken(uuid: Self.localID)))
  }

  /// `isGenerated` (PLAN.md D26): every document the generator makes, whatever its helper path
  /// or parent, counts; the user's files do not: another GUID, a look-alike or uppercase GUID,
  /// no `muxFinder` tag, an extra top-level key, no profiles, not JSON, not an object.
  @Test func recognizesGeneratedDocuments() throws {
    let list = try HostList([Self.local, Self.other, Self.remote])
    for helper in [Self.helper, "/Users/tester/Applications/muxfinder-launch"] {
      let document = try PersistentProfiles.document(for: list, helperPath: helper)
      #expect(PersistentProfiles.isGenerated(document.data))
    }
    #expect(PersistentProfiles.isGenerated(Data(try Self.golden("with-parent").utf8)))
    let guid = PersistentProfiles.guid(forHostID: Self.localID)
    let tagged = #""Tags": ["muxFinder"]"#
    let refused = [
      #"{"Profiles": [{"Guid": "mine-1", \#(tagged)}]}"#,
      #"{"Profiles": [{"Guid": "muxfinder-persistent-custom", \#(tagged)}]}"#,
      #"{"Profiles": [{"Guid": "\#(guid.uppercased())", \#(tagged)}]}"#,
      #"{"Profiles": [{"Guid": "\#(guid)x", \#(tagged)}]}"#,
      #"{"Profiles": [{"Guid": "\#(guid)", "Tags": ["Mine"]}]}"#,
      #"{"Profiles": [{"Guid": "\#(guid)"}]}"#,
      #"{"Profiles": [{"Guid": "\#(guid)", \#(tagged)}], "Mine": true}"#,
      #"{"Profiles": [{"Guid": "\#(guid)", \#(tagged)}, {"Guid": "mine-1", \#(tagged)}]}"#,
      #"{"Profiles": []}"#,
      #"{"Profiles": {}}"#,
      #"[{"Guid": "\#(guid)", \#(tagged)}]"#,
      "not JSON",
      "",
    ]
    for text in refused {
      #expect(!PersistentProfiles.isGenerated(Data(text.utf8)), "\(text)")
    }
    let minimal = #"{"Profiles": [{"Guid": "\#(guid)", \#(tagged)}]}"#
    #expect(PersistentProfiles.isGenerated(Data(minimal.utf8)))
  } // End of func recognizesGeneratedDocuments()
}
