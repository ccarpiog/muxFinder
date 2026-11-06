import Foundation
import Testing

@testable import MuxFinderCore

/// The terminal definition schema (PLAN.md D38, Phase I-12b1): every refusal, the accepted
/// forms, version comparison, and the two built-ins read from `Resources/Terminals/` with the
/// forbidden commands absent from their scripts. No script is compiled here.
@Suite("Terminal definitions")
struct TerminalDefinitionTests {
  /// Shorthand for the support enum.
  typealias Support = TerminalDefinitionTestSupport

  // MARK: - Accepted forms

  /// A full `appleScript` definition reads with every field.
  @Test func readsAnAppleScriptDefinition() throws {
    var object = Support.appleScriptObject()
    object["notes"] = "Line one.\n\tLine two."
    object["keepsMinimumLifetime"] = false
    let definition = try TerminalDefinition.decode(try Support.data(object))
    #expect(definition.id == "sample")
    #expect(definition.displayName == "Sample terminal")
    #expect(definition.bundleIdentifier == "com.example.sample-terminal")
    #expect(definition.minimumVersion == TerminalVersion("1.0"))
    #expect(definition.notes == "Line one.\n\tLine two.")
    #expect(definition.open == .appleScript(script: "sample.applescript", command: .words))
    #expect(definition.open.kind == "appleScript")
    #expect(definition.open.commandForm == .words)
    #expect(definition.focus == .windowID)
    #expect(!definition.keepsMinimumLifetime)
    #expect(definition.needsAutomationPermission)
  } // End of func readsAnAppleScriptDefinition()

  /// An `exec` definition reads its argv template, literal arguments kept and placeholders
  /// recognized; it needs no Automation permission.
  @Test func readsAnExecDefinition() throws {
    let definition = try TerminalDefinition.decode(try Support.data(Support.execObject()))
    #expect(
      definition.open
        == .exec(
          executable: "Contents/MacOS/sample-terminal",
          arguments: [
            .literal("start"), .literal("--always-new-process"), .literal("--"),
            .placeholder(.helper), .placeholder(.mode), .placeholder(.token),
          ]))
    #expect(definition.open.commandForm == nil)
    #expect(definition.focus == .app)
    #expect(definition.keepsMinimumLifetime)
    #expect(!definition.needsAutomationPermission)
  } // End of func readsAnExecDefinition()

  /// Optional fields take their defaults, `app` focus works with `appleScript`, and the
  /// limits' edges are accepted: a 32-byte id, a 64-character display name (emoji count as
  /// one), 1024 bytes of notes, an empty literal argument.
  @Test func acceptsTheEdges() throws {
    var object = Support.appleScriptObject(id: String(repeating: "a", count: 31) + "-")
    object["displayName"] = String(repeating: "é", count: 63) + "👩‍💻"
    object["notes"] = String(repeating: "n", count: 1024)
    object["focus"] = ["kind": "app"]
    object["open"] = ["kind": "appleScript", "script": "a.applescript", "command": "shellText"]
    let definition = try TerminalDefinition.decode(try Support.data(object))
    #expect(definition.focus == .app)
    #expect(definition.open.commandForm == .shellText)
    var exec = Support.execObject()
    exec["open"] = [
      "kind": "exec", "executable": "Contents/MacOS/x y",
      "arguments": ["", "{token}", "{mode}", "{helper}"],
    ]
    #expect(try Support.problem(exec) == nil)
  } // End of func acceptsTheEdges()

  // MARK: - Refusals

  /// Anything that is not a JSON object.
  @Test func refusesWhatIsNotAnObject() throws {
    #expect(Support.problem(decoding: Data("{".utf8)) == .notJSON)
    #expect(Support.problem(decoding: Data()) == .notJSON)
    #expect(Support.problem(decoding: Data([0xFF, 0xFE, 0x00])) == .notJSON)
    #expect(try Support.problem([Support.appleScriptObject()]) == .notAnObject)
  }

  /// `schemaVersion` must be the whole number 1: missing, newer, zero, negative, text, a
  /// fraction and a boolean are refused.
  @Test func refusesWrongSchemaVersions() throws {
    let object = Support.appleScriptObject()
    #expect(
      try Support.problem(Support.setting("schemaVersion", to: nil, in: object))
        == .missingSchemaVersion)
    #expect(
      try Support.problem(Support.setting("schemaVersion", to: 2, in: object))
        == .newerSchemaVersion(2))
    #expect(
      try Support.problem(Support.setting("schemaVersion", to: 0, in: object))
        == .unsupportedSchemaVersion(0))
    #expect(
      try Support.problem(Support.setting("schemaVersion", to: -1, in: object))
        == .unsupportedSchemaVersion(-1))
    for value: Any in ["1", 1.5, true] {
      #expect(
        try Support.problem(Support.setting("schemaVersion", to: value, in: object))
          == .wrongType(key: "schemaVersion", expected: .wholeNumber))
    }
    // A newer version is reported before its unknown keys.
    var newer = Support.setting("schemaVersion", to: 3, in: object)
    newer["laterKey"] = true
    #expect(try Support.problem(newer) == .newerSchemaVersion(3))
    // Written as JSON text: an exponent, and a number too large for an Int, are not 1.
    for written in ["1e0", "1.0", "99999999999999999999999", "18446744073709551617"] {
      let text = "{\"schemaVersion\": \(written), \"id\": \"x\"}"
      #expect(
        Support.problem(decoding: Data(text.utf8))
          == .wrongType(key: "schemaVersion", expected: .wholeNumber))
    }
  } // End of func refusesWrongSchemaVersions()

  /// An unknown key is refused at every level: the top, `open` of each kind, and `focus`.
  @Test func refusesUnknownKeysAtEveryLevel() throws {
    let apple = Support.appleScriptObject()
    let exec = Support.execObject()
    #expect(try Support.problem(Support.setting("extra", to: 1, in: apple)) == .unknownKey("extra"))
    #expect(try Support.problem(Support.setting("Id", to: "x", in: apple)) == .unknownKey("Id"))
    #expect(
      try Support.problem(Support.setting("extra", of: "open", to: 1, in: apple))
        == .unknownKey("open.extra"))
    // A key of the other open kind is unknown too.
    #expect(
      try Support.problem(Support.setting("arguments", of: "open", to: [], in: apple))
        == .unknownKey("open.arguments"))
    #expect(
      try Support.problem(Support.setting("script", of: "open", to: "a.applescript", in: exec))
        == .unknownKey("open.script"))
    #expect(
      try Support.problem(Support.setting("extra", of: "focus", to: "x", in: apple))
        == .unknownKey("focus.extra"))
    #expect(
      try Support.problem(Support.setting("handler", of: "focus", to: "x", in: exec))
        == .unknownKey("focus.handler"))
  } // End of func refusesUnknownKeysAtEveryLevel()

  /// A missing required key is named; a value of the wrong JSON type is refused.
  @Test func refusesMissingKeysAndWrongTypes() throws {
    let object = Support.appleScriptObject()
    for key in ["id", "displayName", "bundleIdentifier", "minimumVersion", "open", "focus"] {
      #expect(try Support.problem(Support.setting(key, to: nil, in: object)) == .missingKey(key))
    }
    #expect(
      try Support.problem(Support.setting("kind", of: "open", to: nil, in: object))
        == .missingKey("open.kind"))
    #expect(
      try Support.problem(Support.setting("script", of: "open", to: nil, in: object))
        == .missingKey("open.script"))
    #expect(
      try Support.problem(Support.setting("command", of: "open", to: nil, in: object))
        == .missingKey("open.command"))
    #expect(
      try Support.problem(Support.setting("kind", of: "focus", to: nil, in: object))
        == .missingKey("focus.kind"))
    #expect(
      try Support.problem(
        Support.setting(
          "arguments", of: "open", to: nil,
          in: Support.execObject())) == .missingKey("open.arguments"))
    #expect(
      try Support.problem(Support.setting("displayName", to: 5, in: object))
        == .wrongType(key: "displayName", expected: .text))
    #expect(
      try Support.problem(Support.setting("notes", to: ["x"], in: object))
        == .wrongType(key: "notes", expected: .text))
    for value: Any in [1, "true", 0] {
      #expect(
        try Support.problem(Support.setting("keepsMinimumLifetime", to: value, in: object))
          == .wrongType(key: "keepsMinimumLifetime", expected: .boolean))
    }
    #expect(
      try Support.problem(Support.setting("open", to: "appleScript", in: object))
        == .wrongType(key: "open", expected: .object))
    #expect(
      try Support.problem(Support.setting("focus", to: ["tty"], in: object))
        == .wrongType(key: "focus", expected: .object))
    #expect(
      try Support.problem(
        Support.setting(
          "arguments", of: "open", to: "{helper}",
          in: Support.execObject())) == .wrongType(key: "open.arguments", expected: .list))
    #expect(
      try Support.problem(
        Support.setting(
          "arguments", of: "open", to: ["{helper}", 3],
          in: Support.execObject())) == .wrongType(key: "open.arguments item 2", expected: .text))
  } // End of func refusesMissingKeysAndWrongTypes()

  /// Ids outside `[a-z0-9-]` or 1–32 bytes are refused, and `iterm2` is reserved.
  @Test(arguments: [
    "", "Terminal", "my_term", "my term", "tér", String(repeating: "a", count: 33),
    "a.b", "a/b",
  ])
  func refusesBadIDs(id: String) throws {
    #expect(try Support.problem(Support.appleScriptObject(id: id)) == .invalidID)
  }

  /// `iterm2` is reserved: iTerm2 is code, not a definition.
  @Test func refusesTheReservedID() throws {
    #expect(try Support.problem(Support.appleScriptObject(id: "iterm2")) == .reservedID("iterm2"))
    #expect(try Support.problem(Support.execObject(id: "iterm2")) == .reservedID("iterm2"))
  }

  /// Display names that are empty, too long or hold a control character are refused.
  @Test(arguments: [
    "", String(repeating: "x", count: 65), "two\nlines", "tab\there", "nel\u{85}",
    "del\u{7F}",
  ])
  func refusesBadDisplayNames(name: String) throws {
    #expect(
      try Support.problem(
        Support.setting(
          "displayName", to: name,
          in: Support.appleScriptObject())) == .invalidDisplayName)
  }

  /// Bundle identifiers with empty parts, spaces or other characters are refused.
  @Test(arguments: [
    "", ".com.example", "com..example", "com.example.", "com.ex ample",
    "com.ex_ample", "com.exämple", String(repeating: "a", count: 256),
  ])
  func refusesBadBundleIdentifiers(identifier: String) throws {
    #expect(
      try Support.problem(
        Support.setting(
          "bundleIdentifier", to: identifier,
          in: Support.appleScriptObject())) == .invalidBundleIdentifier)
  }

  /// Minimum versions that are not dotted decimal are refused.
  @Test(arguments: [
    "", "1.3-beta", "1..3", ".1", "1.", "v1.3", " 1.3", "1.3 ", "1,3",
    "1234567890", "1.2.3.4.5.6.7.8.9", "١.٣",
  ])
  func refusesBadVersions(version: String) throws {
    #expect(
      try Support.problem(
        Support.setting(
          "minimumVersion", to: version,
          in: Support.appleScriptObject())) == .invalidMinimumVersion)
  }

  /// Notes over 1 KiB or with a control character other than a line break or tab are refused.
  @Test func refusesBadNotes() throws {
    let object = Support.appleScriptObject()
    for notes in [
      String(repeating: "n", count: 1025), "bell\u{7}", "cr\r", String(repeating: "é", count: 513),
    ] {
      #expect(try Support.problem(Support.setting("notes", to: notes, in: object)) == .invalidNotes)
    }
  }

  /// The open kind and command form must be known values.
  @Test func refusesUnknownOpenKindsAndForms() throws {
    let object = Support.appleScriptObject()
    for kind in ["shell", "AppleScript", "", "osascript"] {
      #expect(
        try Support.problem(Support.setting("kind", of: "open", to: kind, in: object))
          == .unknownOpenKind)
    }
    for form in ["argv", "ShellText", ""] {
      #expect(
        try Support.problem(Support.setting("command", of: "open", to: form, in: object))
          == .unknownCommandForm)
    }
    for kind in ["window", "TTY", ""] {
      #expect(
        try Support.problem(Support.setting("kind", of: "focus", to: kind, in: object))
          == .unknownFocusKind)
    }
  } // End of func refusesUnknownOpenKindsAndForms()

  /// Script names must be plain `.applescript` file names in the definition's folder.
  @Test(arguments: [
    "", "../evil.applescript", "sub/x.applescript", "/tmp/x.applescript",
    ".hidden.applescript", ".applescript", "x.json", "x.scpt", "x y.applescript",
    "x\n.applescript", "x.applescript/", String(repeating: "a", count: 54) + ".applescript",
  ])
  func refusesBadScriptNames(name: String) throws {
    #expect(
      try Support.problem(
        Support.setting(
          "script", of: "open", to: name,
          in: Support.appleScriptObject())) == .invalidScriptName)
  }

  /// Executables must be relative paths inside the app: no leading `/`, no `..`, `.` or empty
  /// part, no control character.
  @Test(arguments: [
    "", "/Applications/Evil.app/Contents/MacOS/evil", "../evil", "Contents/../../x",
    "Contents//MacOS/x", "Contents/./MacOS/x", "Contents/MacOS/", "Contents/MacOS/x\n",
  ])
  func refusesBadExecutables(path: String) throws {
    #expect(
      try Support.problem(
        Support.setting(
          "executable", of: "open", to: path,
          in: Support.execObject())) == .invalidExecutable)
  }

  /// A placeholder inside a longer argument, or a stray brace, is refused; so is an unknown
  /// whole placeholder.
  @Test func refusesPlaceholdersThatAreNotWholeArguments() throws {
    let exec = Support.execObject()
    /// The exec definition with every placeholder once and `extra` as argument 5.
    func with(_ extra: String) -> [String: Any] {
      Support.setting(
        "arguments", of: "open",
        to: ["--", "{helper}", "{mode}", "{token}", extra], in: exec)
    }
    for argument in [
      "--x={token}", "{helper}/x", "pre{mode}", "{", "}", "a{b", "{{token}}",
      "{token}{token}",
    ] {
      #expect(try Support.problem(with(argument)) == .placeholderInsideArgument(position: 5))
    }
    for argument in ["{tty}", "{}", "{Helper}", "{ token }"] {
      #expect(try Support.problem(with(argument)) == .unknownPlaceholder(position: 5))
    }
  } // End of func refusesPlaceholdersThatAreNotWholeArguments()

  /// Every placeholder must appear exactly once.
  @Test func refusesMissingOrRepeatedPlaceholders() throws {
    let exec = Support.execObject()
    #expect(
      try Support.problem(
        Support.setting(
          "arguments", of: "open",
          to: ["{helper}", "{token}"], in: exec)) == .placeholderNotOnce(.mode))
    #expect(
      try Support.problem(
        Support.setting(
          "arguments", of: "open",
          to: ["{helper}", "{mode}", "{token}", "{helper}"], in: exec))
        == .placeholderNotOnce(.helper))
    #expect(
      try Support.problem(Support.setting("arguments", of: "open", to: [], in: exec))
        == .placeholderNotOnce(.helper))
  } // End of func refusesMissingOrRepeatedPlaceholders()

  /// Too many arguments, or one too long or with a control character, are refused.
  @Test func refusesBadArgumentLists() throws {
    let exec = Support.execObject()
    let many = ["{helper}", "{mode}", "{token}"] + Array(repeating: "x", count: 62)
    #expect(
      try Support.problem(Support.setting("arguments", of: "open", to: many, in: exec))
        == .tooManyArguments(limit: 64))
    #expect(
      try Support.problem(
        Support.setting(
          "arguments", of: "open",
          to: Array(many.dropLast()), in: exec)) == nil)
    for argument in ["new\nline", "nul\u{0}", String(repeating: "x", count: 4097)] {
      #expect(
        try Support.problem(
          Support.setting(
            "arguments", of: "open",
            to: ["{helper}", argument, "{mode}", "{token}"], in: exec))
          == .invalidArgument(position: 2))
    }
  } // End of func refusesBadArgumentLists()

  /// `tty` and `windowID` focus need an `appleScript` open.
  @Test(arguments: [TerminalFocusKind.tty, .windowID])
  func refusesHandlerFocusWithExec(kind: TerminalFocusKind) throws {
    #expect(
      try Support.problem(
        Support.setting(
          "kind", of: "focus", to: kind.rawValue,
          in: Support.execObject())) == .focusNeedsAppleScript(kind))
  }

  /// Every problem has a plain sentence and a stable code; an unknown key is shown cleaned.
  @Test func problemsReadAsSentences() {
    let problems: [TerminalDefinitionProblem] = [
      .unsafeFile(.symbolicLink), .unsafeFolder(.permissionsNotPrivate), .tooManyFiles(limit: 32),
      .unsafeScript(name: "x.applescript", .tooLarge), .scriptNotText(name: "x.applescript"),
      .notJSON, .newerSchemaVersion(2), .unknownKey("open.extra"), .missingKey("id"),
      .wrongType(key: "notes", expected: .text), .invalidID, .reservedID("iterm2"),
      .placeholderInsideArgument(position: 2), .placeholderNotOnce(.token),
      .focusNeedsAppleScript(.tty), .duplicateID("terminal"), .duplicateKey("open.kind"),
    ]
    for problem in problems {
      #expect(problem.message.hasSuffix("."))
      #expect(problem.message.first?.isUppercase == true || problem.message.hasPrefix("muxFinder"))
      #expect(!problem.code.isEmpty)
    }
    #expect(
      TerminalDefinitionProblem.unsafeFile(.writableByOthers).message
        == "Other users can change this file.")
    #expect(
      TerminalDefinitionProblem.unsafeScript(name: "x.applescript", .missing).message
        == "Its script x.applescript is missing.")
    #expect(
      TerminalDefinitionProblem.duplicateKey("open.kind").message
        == "This file has the key open.kind more than once.")
    #expect(TerminalDefinitionProblem.unknownKey("a\nb").message.contains("a?b"))
    #expect(TerminalDefinitionProblem.duplicateKey("a\nb").message.contains("a?b"))
    #expect(
      TerminalDefinitionProblem.unknownKey(String(repeating: "k", count: 100)).message
        .contains(String(repeating: "k", count: 64) + "…"))
  } // End of func problemsReadAsSentences()

  // MARK: - Duplicate member names (written as raw JSON text)

  /// A top-level key twice is refused whichever value comes first, and even with the same
  /// value twice: `JSONSerialization` would keep one silently.
  @Test func refusesDuplicateTopLevelKeys() {
    #expect(Support.problem(text: Support.definitionText()) == nil)
    #expect(
      Support.problem(text: Support.definitionText(before: #""schemaVersion": 9, "#))
        == .duplicateKey("schemaVersion"))
    #expect(
      Support.problem(text: Support.definitionText(after: #", "schemaVersion": 9"#))
        == .duplicateKey("schemaVersion"))
    #expect(
      Support.problem(text: Support.definitionText(after: #", "id": "other""#))
        == .duplicateKey("id"))
    #expect(
      Support.problem(
        text: Support.definitionText(
          before: #""keepsMinimumLifetime": false, "#,
          after: #", "keepsMinimumLifetime": false"#)) == .duplicateKey("keepsMinimumLifetime"))
    #expect(
      Support.problem(text: Support.definitionText(after: #", "focus": {"kind": "tty"}"#))
        == .duplicateKey("focus"))
  } // End of func refusesDuplicateTopLevelKeys()

  /// A key twice inside `open` (either kind), inside `focus`, or in any object nested deeper,
  /// is refused and named by its path.
  @Test func refusesDuplicateKeysInNestedObjects() {
    let appleScriptOpen = #""kind": "appleScript", "script": "sample.applescript", "#
    #expect(
      Support.problem(
        text: Support.definitionText(
          open: appleScriptOpen + #""command": "words", "command": "shellText""#))
        == .duplicateKey("open.command"))
    #expect(
      Support.problem(
        text: Support.definitionText(
          open: appleScriptOpen + #""command": "words", "kind": "exec""#))
        == .duplicateKey("open.kind"))
    #expect(
      Support.problem(text: Support.definitionText(focus: #""kind": "windowID", "kind": "tty""#))
        == .duplicateKey("focus.kind"))
    #expect(
      Support.problem(
        text: Support.definitionText(open: Support.execOpenText, focus: #""kind": "app""#))
        == nil)
    // The members beside an exec open's `arguments`, and an object inside the list.
    for (open, key) in [
      (
        Support.execOpenText + #", "arguments": ["{helper}", "{mode}", "{token}"]"#,
        "open.arguments"
      ),
      (Support.execOpenText + #", "executable": "Contents/MacOS/other""#, "open.executable"),
      (
        #""kind": "exec", "executable": "Contents/MacOS/x", "#
          + #""arguments": [{"x": 1, "x": 2}, "{helper}", "{mode}", "{token}"]"#,
        "open.arguments item 1.x"
      ),
    ] {
      #expect(
        Support.problem(text: Support.definitionText(open: open, focus: #""kind": "app""#))
          == .duplicateKey(key))
    }
    #expect(
      Support.problem(
        text: Support.definitionText(after: #", "notes": {"a": [0, {"b": 1, "b": 2}]}"#))
        == .duplicateKey("notes.a item 2.b"))
  } // End of func refusesDuplicateKeysInNestedObjects()

  /// Names are compared after their escapes are decoded: `id` with a letter written as a
  /// `\u` escape is `id`, each one-character escape equals its `\u` form, a surrogate pair
  /// equals the character written out, and canonically equivalent names are the same name.
  @Test func refusesDuplicatesSpelledWithEscapes() {
    let u = Support.jsonEscape
    #expect(
      Support.problem(text: Support.definitionText(after: ", \"\(u("0069"))d\": \"other\""))
        == .duplicateKey("id"))
    #expect(
      Support.problem(text: Support.definitionText(before: "\"i\(u("0064"))\": \"other\", "))
        == .duplicateKey("id"))
    #expect(
      Support.problem(
        text: Support.definitionText(
          focus: "\"kind\": \"windowID\", \"\(u("006B", "0069"))nd\": \"tty\""))
        == .duplicateKey("focus.kind"))
    for (first, second, name) in [
      (#"a\"b"#, "a\(u("0022"))b", "a\"b"), (#"a\\b"#, "a\(u("005c"))b", "a\\b"),
      (#"a\/b"#, "a/b", "a/b"), (#"a\/b"#, "a\(u("002F"))b", "a/b"),
      (#"a\bb"#, "a\(u("0008"))b", "a\u{8}b"), (#"a\fb"#, "a\(u("000C"))b", "a\u{C}b"),
      (#"a\nb"#, "a\(u("000a"))b", "a\nb"), (#"a\rb"#, "a\(u("000D"))b", "a\rb"),
      (#"a\tb"#, "a\(u("0009"))b", "a\tb"),
      ("\u{1F600}", u("D83D", "DE00"), "\u{1F600}"), (u("d83d", "de00"), "\u{1F600}", "\u{1F600}"),
      ("caf\(u("00e9"))", "cafe\(u("0301"))", "caf\u{E9}"),
    ] {
      #expect(
        Support.problem(text: Support.definitionText(after: ", \"\(first)\": 1, \"\(second)\": 2"))
          == .duplicateKey(name), "\(first) and \(second)")
    }
  } // End of func refusesDuplicatesSpelledWithEscapes()

  /// Repeats that are not two members of one object still read: equal strings in a list,
  /// one name in two objects, a value equal to a name, names differing only in case.
  @Test func acceptsRepeatsThatAreNotDuplicateNames() throws {
    let open =
      #""kind": "exec", "executable": "Contents/MacOS/x", "#
      + #""arguments": ["--", "--", "{helper}", "{mode}", "{token}"]"#
    let definition = try TerminalDefinition.decode(
      Data(Support.definitionText(open: open, focus: #""kind": "app""#).utf8))
    #expect(
      definition.open
        == .exec(
          executable: "Contents/MacOS/x",
          arguments: [
            .literal("--"), .literal("--"), .placeholder(.helper), .placeholder(.mode),
            .placeholder(.token),
          ]))
    #expect(
      Support.problem(
        text: Support.definitionText(after: #", "notes": "id""#)) == nil)
    #expect(
      Support.problem(text: Support.definitionText(after: #", "Id": "x""#)) == .unknownKey("Id"))
  } // End of func acceptsRepeatsThatAreNotDuplicateNames()

  /// Text the duplicate check cannot follow stays `notJSON`: a UTF-16 file (which
  /// `JSONSerialization` would read), and nesting past 64 levels; malformed text with a
  /// duplicate is `notJSON` too. A UTF-8 byte order mark is still accepted.
  @Test func textTheCheckCannotFollowIsNotJSON() throws {
    let valid = Support.definitionText()
    for text in [valid, Support.definitionText(after: #", "id": "other""#)] {
      let utf16 = try #require(text.data(using: .utf16LittleEndian))
      #expect(try JSONSerialization.jsonObject(with: utf16) is [String: Any])
      #expect(Support.problem(decoding: utf16) == .notJSON)
    }
    #expect(Support.problem(text: #"{"id": "a", "id": "b""#) == .notJSON)
    #expect(Support.problem(decoding: Data([0xEF, 0xBB, 0xBF]) + Data(valid.utf8)) == nil)
    /// The valid definition with `notes` nested `depth` lists deep.
    func nested(_ depth: Int) -> String {
      Support.definitionText(
        after: ", \"notes\": " + String(repeating: "[", count: depth)
          + String(repeating: "]", count: depth))
    }
    #expect(Support.problem(text: nested(63)) == .wrongType(key: "notes", expected: .text))
    #expect(Support.problem(text: nested(64)) == .notJSON)
  } // End of func textTheCheckCannotFollowIsNotJSON()

  // MARK: - Versions

  /// Versions compare numerically, component by component, missing components as zero.
  @Test func comparesVersionsNumerically() throws {
    /// `text` as a version, required to read.
    func version(_ text: String) throws -> TerminalVersion { try #require(TerminalVersion(text)) }
    #expect(try version("1.3") < version("1.3.1"))
    #expect(try version("1.3") == version("1.3.0"))
    #expect(try version("1.3").hashValue == version("1.3.0.0").hashValue)
    #expect(try version("2.15") > version("2.9"))
    #expect(try version("10.0") > version("9.99"))
    #expect(try version("1.10") > version("1.9"))
    #expect(try version("0") == version("0.0"))
    #expect(try !(version("1.3") < version("1.3")))
    #expect(try version("007.1").components == [7, 1])
    #expect(try version("2.15").description == "2.15")
  } // End of func comparesVersionsNumerically()

  /// An installed version meets the minimum only when it reads as a version at least as high;
  /// a missing or unreadable one is unknown, never a pass.
  @Test func checksTheMinimumVersion() throws {
    let minimum = try #require(TerminalVersion("1.3"))
    #expect(TerminalVersion.meets(installed: "1.3.1", minimum: minimum) == true)
    #expect(TerminalVersion.meets(installed: "1.3", minimum: minimum) == true)
    #expect(TerminalVersion.meets(installed: "2", minimum: minimum) == true)
    #expect(TerminalVersion.meets(installed: "1.2.9", minimum: minimum) == false)
    #expect(TerminalVersion.meets(installed: "1.3.1-beta", minimum: minimum) == nil)
    #expect(TerminalVersion.meets(installed: "tip", minimum: minimum) == nil)
    #expect(TerminalVersion.meets(installed: "", minimum: minimum) == nil)
    #expect(TerminalVersion.meets(installed: nil, minimum: minimum) == nil)
  }

  // MARK: - Built-ins

  /// Both built-ins load cleanly from `Resources/Terminals/` with the forms D38 gives them,
  /// and their scripts are read (never compiled).
  @Test func builtInsLoadCleanly() throws {
    let catalog = Support.load(builtIn: Support.builtInDirectory)
    #expect(catalog.problems.isEmpty)
    #expect(Support.sources(catalog) == ["ghostty:builtIn", "terminal:builtIn"])
    let terminal = try #require(catalog.definition(withID: "terminal"))
    #expect(terminal.definition.bundleIdentifier == "com.apple.Terminal")
    #expect(
      terminal.definition.open == .appleScript(script: "terminal.applescript", command: .shellText))
    #expect(terminal.definition.focus == .tty)
    #expect(!terminal.definition.keepsMinimumLifetime)
    #expect(terminal.fileName == "terminal.json")
    #expect(terminal.script?.name == "terminal.applescript")
    let ghostty = try #require(catalog.definition(withID: "ghostty"))
    #expect(ghostty.definition.bundleIdentifier == "com.mitchellh.ghostty")
    #expect(ghostty.definition.minimumVersion == TerminalVersion("1.3"))
    #expect(ghostty.definition.open == .appleScript(script: "ghostty.applescript", command: .words))
    #expect(ghostty.definition.focus == .windowID)
    #expect(!ghostty.definition.keepsMinimumLifetime)
    for loaded in [terminal, ghostty] {
      let source = try #require(loaded.script?.source)
      #expect(source.hasPrefix("-- muxFinder's built-in script for "))
      #expect(source.contains("never builds or changes script source"))
      #expect(source.contains("on muxfinder_open(commandText, helperPath, modeWord, token)"))
      #expect(source.contains("on muxfinder_focus(windowID, ttyName)"))
      #expect(source.contains("on muxfinder_close(windowID)"))
      #expect(source.contains("tell application id \"\(loaded.definition.bundleIdentifier)\""))
    }
  } // End of func builtInsLoadCleanly()

  /// The built-in scripts never use the commands D38 forbids: Terminal's `do script … in`,
  /// `do script in new tab`, `contents` and `history`; Ghostty's `input text`, `send key` and
  /// mouse commands; and neither runs a shell, scripts System Events or types keys.
  @Test func builtInScriptsAvoidForbiddenCommands() throws {
    let catalog = Support.load(builtIn: Support.builtInDirectory)
    let terminal = try #require(catalog.definition(withID: "terminal")?.script?.source)
    let ghostty = try #require(catalog.definition(withID: "ghostty")?.script?.source)
    let everywhere = [
      "do shell script", "system events", "keystroke", "key code",
      "run script", "load script", "store script", "osascript",
    ]
    for (source, forbidden) in [
      (terminal, everywhere + ["contents", "history", "do script in new tab", "input text"]),
      (
        ghostty,
        everywhere + [
          "input text", "send key", "send mouse", "perform action", "initial input",
          "do script",
        ]
      ),
    ] {
      let lowered = source.lowercased()
      for word in forbidden {
        #expect(!lowered.contains(word), "forbidden: \(word)")
      }
    }
    // Terminal's `do script` always opens a new window: never `do script … in`.
    let doScriptLines = terminal.split(separator: "\n").filter { $0.contains("do script") }
    #expect(doScriptLines.count == 1)
    for line in doScriptLines {
      #expect(!line.split(separator: " ").contains("in"))
      #expect(line.trimmingCharacters(in: .whitespaces) == "set newTab to do script commandText")
    }
    // Close only by the recorded id.
    #expect(terminal.contains("window id (windowID as integer)"))
    #expect(ghostty.contains("close window (window id windowID)"))
  } // End of func builtInScriptsAvoidForbiddenCommands()
} // End of struct TerminalDefinitionTests
