import Foundation
import MuxFinderCore
import Testing

/// The core's additions for Phase I-12d2 (PLAN.md D38 *The UI (I-12d2)*), used without
/// `@testable` as the app's preview fixtures use them: a loaded definition and a catalog made
/// in memory from a decoded definition (no file read, no script), and a spawn failure's system
/// reason.
@Suite("Terminal public initializers")
struct TerminalPublicInitTests {
  /// A loaded definition keeps what it is given; the catalog finds it by id and keeps the
  /// problems; the spawn reason reads `strerror`'s text, or nothing.
  @Test func publicInitializersKeepTheirValues() throws {
    let json =
      #"{"schemaVersion": 1, "id": "sample-exec", "displayName": "Sample terminal", "#
      + #""bundleIdentifier": "com.example.sample-terminal", "minimumVersion": "1.0", "#
      + #""open": {"kind": "exec", "executable": "Contents/MacOS/sample", "#
      + #""arguments": ["{helper}", "{mode}", "{token}"]}, "focus": {"kind": "app"}}"#
    let definition = try TerminalDefinition.decode(Data(json.utf8))
    let script = TerminalScript(name: "sample.applescript", source: "")
    let loaded = LoadedTerminalDefinition(
      definition: definition, source: .user, fileName: "sample-exec.json", script: script)
    #expect(loaded.definition == definition)
    #expect(loaded.source == .user && loaded.fileName == "sample-exec.json")
    #expect(loaded.script == script)
    let catalog = TerminalDefinitionCatalog(definitions: [loaded], problems: [])
    #expect(catalog.definition(withID: "sample-exec") == loaded)
    #expect(catalog.definition(withID: "terminal") == nil)
    #expect(catalog.problems.isEmpty)
    #expect(
      PlainTerminalWindowError.reason(of: .spawnFailed(errno: ENOENT))
        == " (No such file or directory)")
    #expect(PlainTerminalWindowError.reason(of: .executableNotAbsolute).isEmpty)
  } // End of func publicInitializersKeepTheirValues()
}
