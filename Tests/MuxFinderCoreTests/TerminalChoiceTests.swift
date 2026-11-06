import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// The terminal setting (PLAN.md D38, Phase I-12c3a): its typed, pure resolution (the default
/// both ways, every unavailable reason, a stored `iterm2` with iTerm2 gone, never replaced), and
/// the `terminal` key of `preferences.json` through `PreferencesStore` (round trip, merging,
/// unchanged writes nothing, the default never written) and `InMemoryPreferencesStore`. Private
/// folders only; nothing reads the real preferences or asks LaunchServices.
@Suite("Terminal choice")
struct TerminalChoiceTests {
  /// The built-in Terminal and Ghostty definitions, loaded as text.
  static func builtIns() throws -> [LoadedTerminalDefinition] {
    TerminalDefinitionTestSupport.load(builtIn: TerminalDefinitionTestSupport.builtInDirectory)
      .definitions
  }

  /// Resolves `stored` over the built-ins (or `definitions`) with every app's version check
  /// `check`.
  static func resolve(
    _ stored: String?,
    iTerm2: Bool,
    check: TerminalAppFacts.VersionCheck = .meets,
    definitions: [LoadedTerminalDefinition]? = nil
  ) throws -> TerminalChoiceResolution {
    try resolveAsking(stored, iTerm2: iTerm2, check: check, definitions: definitions).resolution
  }

  /// `resolve(_:iTerm2:check:definitions:)`, with the ids of the definitions whose version
  /// was asked, in order.
  static func resolveAsking(
    _ stored: String?,
    iTerm2: Bool,
    check: TerminalAppFacts.VersionCheck = .meets,
    definitions: [LoadedTerminalDefinition]? = nil
  ) throws -> (resolution: TerminalChoiceResolution, asked: [String]) {
    let loaded = try definitions ?? builtIns()
    var asked: [String] = []
    let resolution = TerminalChoice.resolve(
      stored: stored, iTerm2Installed: iTerm2, definitions: loaded,
      versionCheck: { definition in
        asked.append(definition.definition.id)
        return check
      })
    return (resolution, asked)
  } // End of static func resolveAsking(_:iTerm2:check:definitions:)

  // MARK: - Resolution

  /// Absent: iTerm2 when installed (no definition asked), otherwise Terminal's definition.
  @Test func theDefaultIsITerm2WhenInstalledElseTerminal() throws {
    let installed = try Self.resolveAsking(nil, iTerm2: true)
    #expect(installed.resolution == .iTerm2)
    #expect(installed.asked.isEmpty)
    let terminal = try #require(try Self.builtIns().first { $0.definition.id == "terminal" })
    let missing = try Self.resolveAsking(nil, iTerm2: false)
    #expect(missing.resolution == .plain(terminal))
    #expect(missing.asked == ["terminal"])
    #expect(TerminalChoice.candidateID(stored: nil, iTerm2Installed: true) == "iterm2")
    #expect(TerminalChoice.candidateID(stored: nil, iTerm2Installed: false) == "terminal")
    #expect(TerminalChoice.candidateID(stored: "ghostty", iTerm2Installed: true) == "ghostty")
  }

  /// A stored definition id resolves to that definition, whether iTerm2 is installed or not;
  /// only its app's version is asked.
  @Test func aStoredDefinitionResolvesToIt() throws {
    let ghostty = try #require(try Self.builtIns().first { $0.definition.id == "ghostty" })
    for installed in [true, false] {
      let resolved = try Self.resolveAsking("ghostty", iTerm2: installed)
      #expect(resolved.resolution == .plain(ghostty))
      #expect(resolved.asked == ["ghostty"])
    }
    let resolution = try Self.resolve("ghostty", iTerm2: true)
    #expect(resolution.chosen == .plain(ghostty))
    #expect(resolution.chosen?.id == "ghostty")
    #expect(resolution.chosen?.terminal == .plain(definitionID: "ghostty"))
    #expect(!resolution.usesITerm2 && resolution.kind == "plain")
    #expect(resolution.terminalID == "ghostty")
  } // End of func aStoredDefinitionResolvesToIt()

  /// A stored `iterm2` with iTerm2 gone is unavailable, never replaced by Terminal.
  @Test func aStoredITerm2WithITerm2GoneIsUnavailable() throws {
    let resolved = try Self.resolveAsking("iterm2", iTerm2: false)
    let resolution = resolved.resolution
    #expect(resolution == .unavailable(.init(terminalID: "iterm2", reason: .notInstalled)))
    #expect(resolved.asked.isEmpty)
    #expect(resolution.chosen == nil && !resolution.usesITerm2)
    #expect(resolution.terminalID == "iterm2" && resolution.kind == "unavailable")
    #expect(try Self.resolve("iterm2", iTerm2: true) == .iTerm2)
    #expect(TerminalChoiceResolution.iTerm2.chosen == .iTerm2)
    #expect(ChosenTerminal.iTerm2.id == "iterm2" && ChosenTerminal.iTerm2.terminal == .iterm2)
  }

  /// Each unavailable reason: an unknown id (a typo, a missing definition, a stored value that
  /// is not a string), the app not installed, too old, or its version unreadable. None is
  /// replaced by another terminal.
  @Test func everyUnavailableReason() throws {
    let terminal = try #require(try Self.builtIns().first { $0.definition.id == "terminal" })
    let minimum = terminal.definition.minimumVersion
    let cases: [(String?, Bool, TerminalAppFacts.VersionCheck, TerminalChoiceUnavailable)] = [
      ("warp", true, .meets, .init(terminalID: "warp", reason: .unknownID)),
      ("", true, .meets, .init(terminalID: "", reason: .unknownID)),
      ("terminal", true, .notInstalled, .init(terminalID: "terminal", reason: .notInstalled)),
      (
        "terminal", true, .tooOld,
        .init(terminalID: "terminal", reason: .versionTooOld(minimum: minimum))
      ),
      (
        nil, false, .unknown,
        .init(terminalID: "terminal", reason: .versionUnknown(minimum: minimum))
      ),
    ]
    for (stored, installed, check, failure) in cases {
      #expect(
        try Self.resolve(stored, iTerm2: installed, check: check) == .unavailable(failure),
        "\(String(describing: stored)) \(check)")
    }
    // No Terminal definition loaded and no iTerm2: the default is unknown, not another one.
    let ghosttyOnly = try Self.builtIns().filter { $0.definition.id == "ghostty" }
    #expect(
      try Self.resolve(nil, iTerm2: false, definitions: ghosttyOnly)
        == .unavailable(.init(terminalID: "terminal", reason: .unknownID)))
  } // End of func everyUnavailableReason()

  /// The failures' kinds and neutral sentences: distinct, a capital or muxFinder first, a
  /// full stop last, naming the id quoted and cut to printable ASCII.
  @Test func unavailableMessagesAreDistinctSentences() {
    let minimum = TerminalVersion("2.0")!
    let reasons: [TerminalChoiceUnavailable.Reason] = [
      .unknownID, .notInstalled, .versionTooOld(minimum: minimum),
      .versionUnknown(minimum: minimum),
    ]
    let failures = reasons.map { TerminalChoiceUnavailable(terminalID: "ghostty", reason: $0) }
    #expect(
      failures.map(\.kind) == ["unknownID", "notInstalled", "versionTooOld", "versionUnknown"])
    #expect(Set(failures.map(\.message)).count == 4)
    for failure in failures {
      #expect(failure.message.contains("“ghostty”"))
      #expect(failure.message.hasSuffix("."))
      let first = failure.message.first.map(String.init) ?? ""
      #expect(first == first.uppercased() || failure.message.hasPrefix("muxFinder"))
    }
    #expect(TerminalChoice.displayID("a\nb\u{7F}é") == "“a?b??”")
    #expect(TerminalChoice.displayID(String(repeating: "x", count: 40)).hasSuffix("…”"))
  } // End of func unavailableMessagesAreDistinctSentences()

  /// The version check of a snapshot: not installed, meets, too old, unknown.
  @Test func versionCheckOfASnapshot() {
    let minimum = TerminalVersion("2.0")!
    let app = URL(fileURLWithPath: "/Applications/Fixture.app")
    let cases: [(TerminalAppSnapshot, TerminalAppFacts.VersionCheck)] = [
      (TerminalAppSnapshot(url: nil, version: "9.0", running: true), .notInstalled),
      (TerminalAppSnapshot(url: app, version: "2.14", running: false), .meets),
      (TerminalAppSnapshot(url: app, version: "1.9", running: true), .tooOld),
      (TerminalAppSnapshot(url: app, version: nil, running: true), .unknown),
      (TerminalAppSnapshot(url: app, version: "beta", running: true), .unknown),
    ]
    for (snapshot, expected) in cases {
      #expect(TerminalAppFacts.versionCheck(of: snapshot, minimum: minimum) == expected)
    }
  } // End of func versionCheckOfASnapshot()

  // MARK: - The preferences key

  /// The `terminal` key round-trips through `PreferencesStore` on a private folder: written only
  /// when it changes, every other key kept, removed again with `nil`, the default never
  /// written.
  @Test func theKeyRoundTripsThroughTheStore() async throws {
    let fixture = try PreferencesStoreTests.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let store = fixture.store
    let none = try await store.setTerminal(nil)
    #expect(!none.wrote)
    #expect(!LaunchTestSupport.exists(fixture.directory), "the default is never written")
    try PreferencesStoreTests.writeFile(
      #"{"folderSearchScope": "disk", "future": [1], "schemaVersion": 1}"#, in: fixture)
    let set = try await store.setTerminal("ghostty")
    #expect(set.wrote && set.preferences.terminal == "ghostty")
    var object = try PreferencesStoreTests.object(at: fixture.file)
    #expect(object["terminal"] as? String == "ghostty")
    #expect(object["folderSearchScope"] as? String == "disk")
    #expect((object["future"] as? [Int]) == [1])
    let loaded = try await store.load()
    #expect(loaded.state == .saved)
    #expect(loaded.preferences.terminal == "ghostty")
    #expect(loaded.preferences.folderSearchScope == .disk)
    let again = try await store.setTerminal("ghostty")
    #expect(!again.wrote)
    let iTerm2 = try await store.setTerminal("iterm2")
    #expect(iTerm2.wrote)
    #expect(try await store.load().preferences.terminal == "iterm2")
    let cleared = try await store.setTerminal(nil)
    #expect(cleared.wrote && cleared.preferences.terminal == nil)
    object = try PreferencesStoreTests.object(at: fixture.file)
    #expect(object["terminal"] == nil)
    #expect(object["folderSearchScope"] as? String == "disk")
    #expect(try await store.setTerminal(nil).wrote == false)
  } // End of func theKeyRoundTripsThroughTheStore()

  /// Reading: `null` and no key are absent; a value that is not a string reads as the empty id
  /// (no terminal, so unavailable, never the default); the file stays usable. A file that
  /// cannot be used refuses a change and is left as it is.
  @Test func readingAndRefusals() async throws {
    let fixture = try PreferencesStoreTests.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let texts: [(String, String?)] = [
      (#"{"schemaVersion": 1}"#, nil),
      (#"{"schemaVersion": 1, "terminal": null}"#, nil),
      (#"{"schemaVersion": 1, "terminal": "terminal"}"#, "terminal"),
      (#"{"schemaVersion": 1, "terminal": 7}"#, ""),
      (#"{"schemaVersion": 1, "terminal": {"id": "x"}}"#, ""),
    ]
    for (text, expected) in texts {
      try PreferencesStoreTests.writeFile(text, in: fixture)
      let loaded = try await fixture.store.load()
      #expect(loaded.state == .saved, "\(text)")
      #expect(loaded.preferences.terminal == expected, "\(text)")
    }
    try PreferencesStoreTests.writeFile("not json", in: fixture)
    await #expect(throws: PreferencesStoreError.fileNotUsable(.notJSON)) {
      _ = try await fixture.store.setTerminal("ghostty")
    }
    #expect(try String(contentsOf: fixture.file, encoding: .utf8) == "not json")
  } // End of func readingAndRefusals()

  /// The in-memory store keeps the value and counts real changes.
  @Test func theInMemoryStoreKeepsIt() async throws {
    let store = InMemoryPreferencesStore(Preferences(terminal: "terminal"))
    #expect(await store.load().preferences.terminal == "terminal")
    _ = try await store.setTerminal("terminal")
    #expect(await store.changeCount == 0)
    _ = try await store.setTerminal(nil)
    #expect(await store.changeCount == 1)
    #expect(await store.preferences.terminal == nil)
    await store.setFailure(.busy)
    await #expect(throws: PreferencesStoreError.busy) { _ = try await store.setTerminal("x") }
    #expect(await store.preferences.terminal == nil)
  }
} // End of struct TerminalChoiceTests
