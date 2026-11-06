import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// Synthetic terminal definitions, private folders and the repository's built-ins for the
/// terminal definition tests (PLAN.md D38, Phase I-12b1). Nothing here compiles a script or
/// touches the real `~/Library/Application Support/muxFinder/terminals/`.
enum TerminalDefinitionTestSupport {
  /// The repository's `Resources/Terminals/`, found from this file's path.
  static let builtInDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Resources/Terminals", directoryHint: .isDirectory)

  /// A valid `appleScript` definition object with `id`.
  static func appleScriptObject(id: String = "sample") -> [String: Any] {
    [
      "schemaVersion": 1,
      "id": id,
      "displayName": "Sample terminal",
      "bundleIdentifier": "com.example.sample-terminal",
      "minimumVersion": "1.0",
      "open": ["kind": "appleScript", "script": "sample.applescript", "command": "words"],
      "focus": ["kind": "windowID"],
    ]
  }

  /// A valid `exec` definition object with `id`.
  static func execObject(id: String = "sample-exec") -> [String: Any] {
    [
      "schemaVersion": 1,
      "id": id,
      "displayName": "Sample exec terminal",
      "bundleIdentifier": "com.example.exec-terminal",
      "minimumVersion": "20240203",
      "notes": "Runs its own program.\nNo AppleScript.",
      "open": [
        "kind": "exec",
        "executable": "Contents/MacOS/sample-terminal",
        "arguments": ["start", "--always-new-process", "--", "{helper}", "{mode}", "{token}"],
      ],
      "focus": ["kind": "app"],
      "keepsMinimumLifetime": true,
    ]
  } // End of static func execObject(id:)

  /// `object` as JSON bytes.
  static func data(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
  }

  /// The problem decoding `object` gives, or `nil` when it decodes.
  static func problem(_ object: Any) throws -> TerminalDefinitionProblem? {
    problem(decoding: try data(object))
  }

  /// The problem decoding `data` gives, or `nil` when it decodes.
  static func problem(decoding data: Data) -> TerminalDefinitionProblem? {
    do throws(TerminalDefinitionProblem) {
      _ = try TerminalDefinition.decode(data)
      return nil
    } catch {
      return error
    }
  }

  /// The members of a valid `exec` open, as JSON text.
  static let execOpenText =
    #""kind": "exec", "executable": "Contents/MacOS/sample-terminal", "#
    + #""arguments": ["{helper}", "{mode}", "{token}"]"#

  /// A valid definition written as raw JSON text (so it can hold what a dictionary cannot,
  /// such as a member name twice): `before` and `after` placed around its own top-level
  /// members, and `open` and `focus` holding the given members (an `appleScript` open with
  /// `windowID` focus by default).
  static func definitionText(
    before: String = "",
    after: String = "",
    open: String = #""kind": "appleScript", "script": "sample.applescript", "command": "words""#,
    focus: String = #""kind": "windowID""#
  ) -> String {
    "{\(before)\"schemaVersion\": 1, \"id\": \"sample\", \"displayName\": \"Sample terminal\", "
      + "\"bundleIdentifier\": \"com.example.sample-terminal\", \"minimumVersion\": \"1.0\", "
      + "\"open\": {\(open)}, \"focus\": {\(focus)}\(after)}"
  }

  /// Each of `units` (four hex digits) as a JSON `\u` escape, joined. Built at run time, so
  /// no test source holds such an escape written out.
  static func jsonEscape(_ units: String...) -> String {
    units.map { "\\" + "u" + $0 }.joined()
  }

  /// The problem decoding the JSON text `text` gives, or `nil` when it decodes.
  static func problem(text: String) -> TerminalDefinitionProblem? {
    problem(decoding: Data(text.utf8))
  }

  /// `object` with `value` at `key` (`nil` removes it).
  static func setting(_ key: String, to value: Any?, in object: [String: Any]) -> [String: Any] {
    var copy = object
    copy[key] = value
    return copy
  }

  /// `object` with `value` at `key` of its nested object `parent` (`nil` removes it).
  static func setting(
    _ key: String,
    of parent: String,
    to value: Any?,
    in object: [String: Any]
  ) -> [String: Any] {
    var copy = object
    var nested = copy[parent] as? [String: Any] ?? [:]
    nested[key] = value
    copy[parent] = nested
    return copy
  }

  /// A fresh private folder with no symbolic link on its path (the temporary directory
  /// resolved), and in it `terminals/` (mode 0700). The caller removes `base`.
  static func makeUserFolder() throws -> (base: URL, user: URL) {
    let temporary = try TestSupport.makeTemporaryDirectory()
    let base = URL(fileURLWithPath: try resolved(temporary), isDirectory: true)
    let user = base.appending(path: "terminals", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: user, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try #require(chmod(user.path(percentEncoded: false), 0o700) == 0)
    return (base, user)
  }

  /// `url`'s path with every symbolic link resolved.
  static func resolved(_ url: URL) throws -> String {
    guard let path = realpath(url.path(percentEncoded: false), nil) else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { free(path) }
    return String(cString: path)
  }

  /// Writes `data` as `name` in `folder` with `mode`.
  static func write(_ data: Data, named name: String, in folder: URL, mode: mode_t = 0o600) throws {
    let url = folder.appending(path: name)
    try data.write(to: url)
    try #require(chmod(url.path(percentEncoded: false), mode) == 0)
  }

  /// Writes the definition `object` as `name`, and for an `appleScript` open a tiny script
  /// (no `tell` block) under its script name, both with `mode`.
  static func writeDefinition(
    _ object: [String: Any],
    named name: String,
    in folder: URL,
    mode: mode_t = 0o600
  ) throws {
    try write(try data(object), named: name, in: folder, mode: mode)
    if let open = object["open"] as? [String: Any], let script = open["script"] as? String {
      try write(Data(sampleScript.utf8), named: script, in: folder, mode: mode)
    }
  }

  /// A script with the three handlers and no `tell` block.
  static let sampleScript = """
    on muxfinder_open(commandText, helperPath, modeWord, token)
    \treturn {"", ""}
    end muxfinder_open
    on muxfinder_focus(windowID, ttyName)
    \treturn
    end muxfinder_focus
    on muxfinder_close(windowID)
    \treturn
    end muxfinder_close
    """

  /// Loads with these folders as the current user.
  static func load(builtIn: URL? = nil, user: URL? = nil) -> TerminalDefinitionCatalog {
    TerminalDefinitionLoader(builtInDirectory: builtIn, userDirectory: user).load()
  }

  /// The problems of `catalog` as `(folder, file, problem)` triples, for comparisons.
  static func problems(
    _ catalog: TerminalDefinitionCatalog
  ) -> [String] {
    catalog.problems.map { "\($0.folder.rawValue)/\($0.fileName): \($0.problem.code)" }
  }

  /// The ids and sources of `catalog`'s definitions, as `id:source` texts.
  static func sources(_ catalog: TerminalDefinitionCatalog) -> [String] {
    catalog.definitions.map { "\($0.definition.id):\($0.source.rawValue)" }
  }
} // End of enum TerminalDefinitionTestSupport
