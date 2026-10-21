import Foundation
import Testing

@testable import MuxFinderCore

/// One request and the fixture its encoding must match byte for byte.
struct GoldenRequest: Sendable, CustomTestStringConvertible {
  /// The fixture's file name in `Fixtures/iterm2/`, without `.bin`.
  let fixture: String
  /// The request.
  let message: ITerm2API.ClientOriginatedMessage

  /// The fixture name.
  var testDescription: String { fixture }
}

/// Synthetic values shared with `scripts/dev/gen-iterm2-fixtures.py`.
enum ITerm2Fixture {
  /// Session ids 1...7 of the generator (`SESSION_1` …).
  static func session(_ number: Int) -> String {
    "00000000-0000-4000-8000-00000000000\(number)"
  }

  /// The generator's `session_summary(SESSION_<number>, "fixture-title-<number>")`.
  static func summary(_ number: Int) -> ITerm2API.SessionSummary {
    ITerm2API.SessionSummary(uniqueIdentifier: session(number), title: "fixture-title-\(number)")
  }

  /// `GUID_1`.
  static let guid1 = "00000000-0000-4000-8000-0000000000a1"
  /// `GUID_2`.
  static let guid2 = "00000000-0000-4000-8000-0000000000a2"
  /// `LAUNCH_COMMAND`.
  static let launchCommand =
    "/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch attach "
    + "00000000-0000-0000-0000-000000000000"
  /// `ESCAPING_COMMAND`: every JSON escape Python's `json.dumps` produces.
  static let escapingCommand =
    "/tmp/fixture dir/run \"quoted\" 'single' back\\slash \u{08}\u{0C}\n\r\t "
    + "\u{01}\u{1F}\u{7F} \u{FC} \u{65E5}\u{672C} \u{1F9EA} end"

  /// The bytes of `Fixtures/iterm2/<name>.bin`.
  static func data(_ name: String) throws -> Data {
    try TestSupport.fixture("iterm2/\(name).bin")
  }

  /// The decoded server message of `Fixtures/iterm2/<name>.bin`.
  static func server(_ name: String) throws -> ITerm2API.ServerOriginatedMessage {
    try ITerm2API.ServerOriginatedMessage(decoding: data(name))
  }
}

/// Golden tests: requests encode exactly as iTerm2's Python module serializes them, and
/// synthetic responses generated with `api_pb2` decode to the expected values.
@Suite("iTerm2 golden messages")
struct ITerm2GoldenTests {
  /// Every request fixture and the typed request that must produce it.
  static let requests: [GoldenRequest] = [
    GoldenRequest(
      fixture: "list-sessions-request", message: .init(id: 1, request: .listSessions(.init()))),
    GoldenRequest(
      fixture: "create-tab-request-command",
      message: .init(
        id: 2,
        request: .createTab(
          .init(
            profileName: "fixture-profile-1",
            customProfileProperties: ITerm2API.ProfileProperty.customCommand("/usr/bin/true")))
      )),
    GoldenRequest(
      fixture: "create-tab-request-launch",
      message: .init(
        id: (1 << 40) + 5,
        request: .createTab(
          .init(
            profileName: "fixture-profile-1",
            windowID: "fixture-window-1",
            tabIndex: 0,
            customProfileProperties: ITerm2API.ProfileProperty.customCommand(
              ITerm2Fixture.launchCommand) + [ITerm2API.ProfileProperty.closeSessionsOnEnd(true)]
          ))
      )),
    GoldenRequest(
      fixture: "create-tab-request-escaping",
      message: .init(
        id: 3,
        request: .createTab(
          .init(
            customProfileProperties: ITerm2API.ProfileProperty.customCommand(
              ITerm2Fixture.escapingCommand)))
      )),
    GoldenRequest(
      fixture: "activate-request-session",
      message: .init(
        id: 4,
        request: .activate(
          .init(
            target: .session(ITerm2Fixture.session(1)), orderWindowFront: true, selectTab: true,
            selectSession: true))
      )),
    GoldenRequest(
      fixture: "activate-request-tab",
      message: .init(
        id: 5,
        request: .activate(
          .init(target: .tab("7"), orderWindowFront: false, selectTab: true, selectSession: false))
      )),
    GoldenRequest(
      fixture: "activate-request-window",
      message: .init(
        id: 6,
        request: .activate(
          .init(
            target: .window("fixture-window-1"), orderWindowFront: true, selectTab: false,
            selectSession: false))
      )),
    GoldenRequest(
      fixture: "activate-request-app",
      message: .init(
        id: 7,
        request: .activate(
          .init(
            target: nil, orderWindowFront: false, selectTab: false, selectSession: false,
            activateApp: .init(raiseAllWindows: true, ignoringOtherApps: true)))
      )),
    GoldenRequest(
      fixture: "list-profiles-request-all", message: .init(id: 8, request: .listProfiles(.init()))),
    GoldenRequest(
      fixture: "list-profiles-request-filtered",
      message: .init(
        id: 9,
        request: .listProfiles(
          .init(
            properties: ["Guid", "Name"], guids: [ITerm2Fixture.guid1, ITerm2Fixture.guid2]))
      )),
    GoldenRequest(
      fixture: "tmux-list-connections-request",
      message: .init(id: 10, request: .tmux(.listConnections))),
    GoldenRequest(
      fixture: "tmux-send-command-request",
      message: .init(
        id: 11,
        request: .tmux(
          .sendCommand(
            connectionID: "fixture-connection-1", command: "display-message -p '#{pid}'"))
      )),
  ]

  /// Every response fixture; each has its own decoding test below.
  static let responseFixtures = [
    "list-sessions-response", "create-tab-response-ok", "create-tab-response-invalid-profile",
    "activate-response-ok", "activate-response-bad-identifier", "list-profiles-response",
    "tmux-list-connections-response", "tmux-send-command-response",
    "tmux-response-invalid-connection", "error-response", "variable-response-unsupported",
    "notification-unsupported", "list-sessions-response-reserialized",
    "list-sessions-response-split", "create-tab-response-unknown-fields",
    "create-tab-response-then-unmodeled", "create-tab-response-after-unmodeled",
    "activate-response-split", "tmux-send-command-response-split",
  ]

  /// Each request encodes byte for byte like its `api_pb2` fixture.
  @Test(arguments: requests)
  func requestMatchesFixture(_ golden: GoldenRequest) throws {
    let expected = try ITerm2Fixture.data(golden.fixture)
    let actual = golden.message.encode()
    #expect(
      actual == expected,
      "\(golden.fixture): got \(actual.map { String(format: "%02x", $0) }.joined())")
  }

  /// The fixture directory holds exactly the fixtures these tests cover.
  @Test func everyFixtureIsCovered() throws {
    let root = try #require(Bundle.module.resourceURL).appending(path: "Fixtures/iterm2")
    let names = try FileManager.default.contentsOfDirectory(
      atPath: root.path(percentEncoded: false))
    let expected = Self.requests.map(\.fixture) + Self.responseFixtures
    #expect(Set(names) == Set(expected.map { "\($0).bin" }))
  }

  /// No fixture holds anything specific to this machine or its user.
  @Test func fixturesHoldOnlySyntheticValues() throws {
    let forbidden = ["/users/", "ccarpio", "carlos", "neptuno", "saturno", "sirio", ".local"]
    for name in Self.requests.map(\.fixture) + Self.responseFixtures {
      let text = String(decoding: try ITerm2Fixture.data(name), as: UTF8.self).lowercased()
      for word in forbidden {
        #expect(!text.contains(word), "\(name) contains \(word)")
      }
    }
  }

  /// The list-sessions response: windows, tabs, nested splits, tmux fields, minimized and
  /// buried sessions, with geometry and unknown fields of every wire type skipped. The original
  /// fixture carries unknown top-level fields before the id; Python's re-serialization of it
  /// carries them after the response, where they must not replace it either.
  @Test(arguments: ["list-sessions-response", "list-sessions-response-reserialized"])
  func decodesListSessions(_ fixture: String) throws {
    let message = try ITerm2Fixture.server(fixture)
    #expect(message.id == 1)
    guard case .listSessions(let response) = message.response else {
      Issue.record("expected a list-sessions response, got \(String(describing: message.response))")
      return
    }
    let summary = ITerm2Fixture.summary
    let expected = ITerm2API.ListSessionsResponse(
      windows: [
        ITerm2API.Window(
          windowID: "fixture-window-1",
          tabs: [
            ITerm2API.Tab(
              tabID: "1",
              root: ITerm2API.SplitTreeNode(
                vertical: false,
                links: [
                  .session(summary(1)),
                  .node(
                    .init(vertical: true, links: [.session(summary(2)), .session(summary(3))])),
                ])),
            ITerm2API.Tab(
              tabID: "2",
              root: ITerm2API.SplitTreeNode(vertical: true, links: [.session(summary(4))]),
              tmuxWindowID: "3",
              tmuxConnectionID: "fixture-connection-1",
              minimizedSessions: [summary(5)]),
          ]),
        ITerm2API.Window(
          windowID: "fixture-window-2",
          tabs: [
            ITerm2API.Tab(
              tabID: "3",
              root: ITerm2API.SplitTreeNode(
                links: [
                  .session(
                    .init(
                      uniqueIdentifier: ITerm2Fixture.session(6), title: "fixture-title-6 ü"))
                ]))
          ]),
      ],
      buriedSessions: [summary(7)])
    #expect(response == expected)
    let firstTab = try #require(response.windows.first?.tabs.first)
    #expect(firstTab.sessions.map(\.uniqueIdentifier) == (1...3).map(ITerm2Fixture.session))
    let tmuxTab = try #require(response.windows.first?.tabs.last)
    #expect(tmuxTab.sessions.map(\.uniqueIdentifier) == [4, 5].map(ITerm2Fixture.session))
  } // End of func decodesListSessions(_:)

  /// A list-sessions response split across two occurrences, whose tab's `root` arrives twice
  /// and whose links arrive in pieces, decodes to the merged value `api_pb2` parses: windows and
  /// links append, `vertical` keeps its last value, split sessions and nodes merge, and a link
  /// that switches from `node` to `session` keeps only the session.
  @Test func decodesSplitListSessions() throws {
    let summary = ITerm2Fixture.summary
    let expected = ITerm2API.ServerOriginatedMessage(
      id: 18,
      response: .listSessions(
        .init(
          windows: [
            ITerm2API.Window(
              windowID: "fixture-window-1",
              tabs: [
                ITerm2API.Tab(
                  tabID: "1",
                  root: ITerm2API.SplitTreeNode(
                    vertical: true,
                    links: [
                      .session(summary(1)),
                      .node(.init(vertical: true, links: [.session(summary(2))])),
                      .session(summary(3)),
                      .session(summary(6)),
                    ]),
                  tmuxWindowID: "3")
              ]),
            ITerm2API.Window(
              windowID: "fixture-window-2",
              tabs: [
                ITerm2API.Tab(
                  tabID: "2", root: ITerm2API.SplitTreeNode(links: [.session(summary(4))]))
              ]),
          ],
          buriedSessions: [summary(5)])))
    #expect(try ITerm2Fixture.server("list-sessions-response-split") == expected)
  } // End of func decodesSplitListSessions()

  /// Repeated occurrences of the same response merge: an empty second occurrence keeps the
  /// first one's activate status (the reviewed bytes) and send-command output.
  @Test func repeatedResponsesMerge() throws {
    let split: [UInt8] = [0x08, 0x01, 0x92, 0x07, 0x02, 0x08, 0x01, 0x92, 0x07, 0x00]
    #expect([UInt8](try ITerm2Fixture.data("activate-response-split")) == split)
    let expected = ITerm2API.ServerOriginatedMessage(
      id: 1, response: .activate(.init(status: .badIdentifier)))
    #expect(try ITerm2API.ServerOriginatedMessage(decoding: Data(split)) == expected)
    #expect(try ITerm2Fixture.server("activate-response-split") == expected)
    #expect(
      try ITerm2Fixture.server("tmux-send-command-response-split")
        == .init(id: 19, response: .tmux(.init(payload: .sendCommand(output: "4242"), status: .ok)))
    )
  } // End of func repeatedResponsesMerge()

  /// Fields that are not in the proto (before and after the response), and a oneof member with
  /// the wrong wire type, never replace the response; between members of the oneof, the last
  /// one wins, and a member that returns after another starts afresh.
  @Test func unknownFieldsAndOneofMembers() throws {
    let createTab = ITerm2API.CreateTabResponse(
      status: .ok, windowID: "fixture-window-1", tabID: 7, sessionID: ITerm2Fixture.session(1))
    #expect(
      try ITerm2Fixture.server("create-tab-response-unknown-fields")
        == .init(id: 15, response: .createTab(createTab)))
    #expect(
      try ITerm2Fixture.server("create-tab-response-then-unmodeled")
        == .init(id: 16, response: .unsupported(fieldNumber: 115)))
    #expect(
      try ITerm2Fixture.server("create-tab-response-after-unmodeled")
        == .init(id: 17, response: .createTab(createTab)))
  } // End of func unknownFieldsAndOneofMembers()

  /// Create-tab responses: success with ids (an `int32` tab id), and an error status.
  @Test func decodesCreateTab() throws {
    let ok = try ITerm2Fixture.server("create-tab-response-ok")
    #expect(ok.id == 2)
    #expect(
      ok.response
        == .createTab(
          .init(
            status: .ok, windowID: "fixture-window-1", tabID: 7,
            sessionID: ITerm2Fixture.session(1))))
    let failed = try ITerm2Fixture.server("create-tab-response-invalid-profile")
    #expect(failed == .init(id: 3, response: .createTab(.init(status: .invalidProfileName))))
  } // End of func decodesCreateTab()

  /// Activate responses with both statuses.
  @Test func decodesActivate() throws {
    #expect(
      try ITerm2Fixture.server("activate-response-ok")
        == .init(id: 4, response: .activate(.init(status: .ok))))
    #expect(
      try ITerm2Fixture.server("activate-response-bad-identifier")
        == .init(id: 5, response: .activate(.init(status: .badIdentifier))))
  }

  /// The list-profiles response, with the name and GUID helpers (JSON strings with escapes).
  @Test func decodesListProfiles() throws {
    let message = try ITerm2Fixture.server("list-profiles-response")
    #expect(message.id == 9)
    guard case .listProfiles(let response) = message.response else {
      Issue.record("expected a list-profiles response")
      return
    }
    #expect(response.profiles.count == 2)
    let first = try #require(response.profiles.first)
    #expect(
      first.properties.map(\.key) == ["Guid", "Name", "Custom Command", "Close Sessions On End"])
    #expect(first.name == "fixture-profile-1")
    #expect(first.guid == ITerm2Fixture.guid1)
    #expect(first.jsonValue(forKey: "Close Sessions On End") == "true")
    #expect(first.stringValue(forKey: "Custom Command") == "No")
    #expect(first.stringValue(forKey: "Close Sessions On End") == nil)
    #expect(first.jsonValue(forKey: "Missing") == nil)
    let second = try #require(response.profiles.last)
    #expect(second.name == "fixture \"quoted\" ü")
    #expect(second.guid == ITerm2Fixture.guid2)
  } // End of func decodesListProfiles()

  /// Tmux responses: connections (one with unknown fields of every wire type), command output,
  /// and an error status without a payload.
  @Test func decodesTmux() throws {
    let connections = try ITerm2Fixture.server("tmux-list-connections-response")
    #expect(
      connections
        == .init(
          id: 10,
          response: .tmux(
            .init(
              payload: .listConnections([
                .init(
                  connectionID: "fixture-connection-1", owningSessionID: ITerm2Fixture.session(4)),
                .init(
                  connectionID: "fixture-connection-2", owningSessionID: ITerm2Fixture.session(6)),
              ]),
              status: .ok))))
    #expect(
      try ITerm2Fixture.server("tmux-send-command-response")
        == .init(id: 11, response: .tmux(.init(payload: .sendCommand(output: "4242"), status: .ok)))
    )
    #expect(
      try ITerm2Fixture.server("tmux-response-invalid-connection")
        == .init(id: 12, response: .tmux(.init(payload: nil, status: .invalidConnectionID))))
  } // End of func decodesTmux()

  /// The error member of the oneof, and submessages this package does not model (a notification
  /// carries no id).
  @Test func decodesErrorsAndUnsupportedMessages() throws {
    #expect(
      try ITerm2Fixture.server("error-response")
        == .init(id: 13, response: .error("fixture-error-1")))
    #expect(
      try ITerm2Fixture.server("variable-response-unsupported")
        == .init(id: 14, response: .unsupported(fieldNumber: 115)))
    #expect(
      try ITerm2Fixture.server("notification-unsupported")
        == .init(id: nil, response: .unsupported(fieldNumber: 1000)))
  } // End of func decodesErrorsAndUnsupportedMessages()

  /// Unknown enum values decode to `unknown`, including negative ones.
  @Test func unknownEnumValuesAreKept() throws {
    /// A response envelope with `status` set to `value` inside the response `fieldNumber`, where
    /// the status field is `statusField`.
    func envelope(_ fieldNumber: Int, statusField: Int, _ value: Int32) -> Data {
      var writer = ProtoWriter()
      writer.writeInt64(1, 1)
      writer.writeMessage(fieldNumber) { $0.writeEnum(statusField, value) }
      return Data(writer.bytes)
    }
    let decode = ITerm2API.ServerOriginatedMessage.init(decoding:)
    #expect(
      try decode(envelope(108, statusField: 1, 42)).response
        == .createTab(.init(status: .unknown(42))))
    #expect(
      try decode(envelope(108, statusField: 1, -3)).response
        == .createTab(.init(status: .unknown(-3))))
    #expect(
      try decode(envelope(114, statusField: 1, 7)).response == .activate(.init(status: .unknown(7)))
    )
    #expect(
      try decode(envelope(124, statusField: 4, 99)).response == .tmux(.init(status: .unknown(99))))
    #expect(
      try decode(envelope(124, statusField: 4, 3)).response
        == .tmux(.init(status: .invalidWindowID)))
  } // End of func unknownEnumValuesAreKept()

  /// Oneof rules in the envelope: the last member wins, unmodeled members (`notification` and
  /// the response types 100–133 this package does not model) are unsupported, field numbers
  /// outside the oneof are skipped wherever they appear, and the tmux payloads this package does
  /// not model leave the payload empty.
  @Test func envelopeOneofRules() throws {
    var writer = ProtoWriter()
    writer.writeString(2, "first")
    writer.writeMessage(106) { _ in }
    writer.writeString(50, "not a submessage")
    writer.writeString(134, "not in the proto")
    writer.writeString(2_000, "not in the proto")
    writer.writeUInt64(115, 1) // a member with the wrong wire type is an unknown field
    let lastWins = try ITerm2API.ServerOriginatedMessage(decoding: Data(writer.bytes))
    #expect(lastWins == .init(id: nil, response: .listSessions(.init())))

    /// The response of an envelope holding `first`, then `second`.
    func response(
      _ first: (inout ProtoWriter) -> Void, _ second: (inout ProtoWriter) -> Void
    ) throws -> ITerm2API.ServerOriginatedMessage.Response? {
      var writer = ProtoWriter()
      first(&writer)
      second(&writer)
      return try ITerm2API.ServerOriginatedMessage(decoding: Data(writer.bytes)).response
    }
    let activate: (inout ProtoWriter) -> Void = { $0.writeMessage(114) { $0.writeEnum(1, 1) } }
    let badIdentifier = ITerm2API.ServerOriginatedMessage.Response.activate(
      .init(status: .badIdentifier))
    #expect(try response({ $0.writeString(150, "unknown") }, activate) == badIdentifier)
    #expect(try response(activate, { $0.writeString(150, "unknown") }) == badIdentifier)
    #expect(
      try response(activate, { $0.writeMessage(1_000) { _ in } })
        == .unsupported(fieldNumber: 1_000))
    #expect(try response({ $0.writeMessage(115) { _ in } }, activate) == badIdentifier)
    #expect(
      try response(activate, { $0.writeString(2, "fixture-error-1") }) == .error("fixture-error-1"))
    #expect(try response({ $0.writeString(134, "unknown") }, { _ in }) == nil)

    writer = ProtoWriter()
    writer.writeMessage(124) { tmux in
      tmux.writeMessage(1) { $0.writeMessage(1) { $0.writeString(1, "c") } }
      tmux.writeMessage(3) { _ in }
    }
    let hidden = try ITerm2API.ServerOriginatedMessage(decoding: Data(writer.bytes))
    #expect(hidden.response == .tmux(.init(payload: nil, status: .ok)))

    writer = ProtoWriter()
    writer.writeMessage(133) { $0.writeString(1, "x") }
    #expect(
      try ITerm2API.ServerOriginatedMessage(decoding: Data(writer.bytes)).response
        == .unsupported(fieldNumber: 133))
  } // End of func envelopeOneofRules()

  /// Every truncation and every single-byte corruption of every response fixture either decodes
  /// or throws `ProtoWireError`; nothing traps or hangs.
  @Test func corruptedResponsesNeverTrap() throws {
    var outcomes = (decoded: 0, rejected: 0)
    /// Decodes `bytes` and counts the outcome; any error other than `ProtoWireError` fails.
    func attempt(_ bytes: [UInt8], _ label: String) {
      do {
        _ = try ITerm2API.ServerOriginatedMessage(decoding: Data(bytes))
        outcomes.decoded += 1
      } catch is ProtoWireError {
        outcomes.rejected += 1
      } catch {
        Issue.record("\(label): unexpected error \(error)")
      }
    }
    for name in Self.responseFixtures {
      let bytes = [UInt8](try ITerm2Fixture.data(name))
      for length in 0..<bytes.count { attempt(Array(bytes[..<length]), "\(name) cut at \(length)") }
      for index in bytes.indices {
        for value: UInt8 in [0x00, 0x7F, 0x80, 0xFF, bytes[index] ^ 0x01] {
          var corrupted = bytes
          corrupted[index] = value
          attempt(corrupted, "\(name) byte \(index) = \(value)")
        }
      }
    } // End of loop over response fixtures
    #expect(outcomes.decoded > 0)
    #expect(outcomes.rejected > 0)
  } // End of func corruptedResponsesNeverTrap()
}

/// Tests for the JSON helpers used in profile properties.
@Suite("iTerm2 JSON values")
struct ITerm2JSONTests {
  /// Strings and their `json.dumps` encodings.
  static let strings: [(String, String)] = [
    ("", #""""#),
    ("plain", #""plain""#),
    ("/usr/bin/true", #""/usr/bin/true""#),
    (#"say "hi" \ there"#, #""say \"hi\" \\ there""#),
    ("\u{08}\u{0C}\n\r\t", #""\b\f\n\r\t""#),
    ("\u{00}\u{1F}\u{7F}", #""\u0000\u001f\u007f""#),
    ("ü日本", #""\u00fc\u65e5\u672c""#),
    ("🧪", #""\ud83e\uddea""#),
    (" ~", #"" ~""#),
  ]

  /// Strings encode like Python's `json.dumps`: ASCII only, `/` unescaped, lowercase `\u`.
  @Test(arguments: strings)
  func encodesStringsLikePython(value: String, json: String) {
    #expect(ITerm2JSON.encode(value) == json)
    #expect(ITerm2JSON.decodeString(json) == value)
  }

  /// Bools are JSON literals; non-string JSON does not decode as a string.
  @Test func boolsAndNonStrings() {
    #expect(ITerm2JSON.encode(true) == "true")
    #expect(ITerm2JSON.encode(false) == "false")
    #expect(ITerm2JSON.decodeString("true") == nil)
    #expect(ITerm2JSON.decodeString("42") == nil)
    #expect(ITerm2JSON.decodeString("\"unterminated") == nil)
    #expect(ITerm2JSON.decodeString("") == nil)
  }

  /// The custom-command helpers produce the keys and JSON values iTerm2's Python module sends,
  /// in its order.
  @Test func customCommandProperties() {
    let properties = ITerm2API.ProfileProperty.customCommand("/usr/bin/true")
    #expect(
      properties == [
        .init(key: "Custom Command", jsonValue: #""Yes""#),
        .init(key: "Command", jsonValue: #""/usr/bin/true""#),
      ])
    #expect(
      ITerm2API.ProfileProperty.closeSessionsOnEnd(false)
        == .init(key: "Close Sessions On End", jsonValue: "false"))
  } // End of func customCommandProperties()
}
