import CoreFoundation
import Foundation

/// The strict reading of a terminal definition file (PLAN.md D38, Phase I-12b1): schema 1,
/// UTF-8 JSON text, unknown keys and a member name twice in one object refused at every
/// level, every string checked, the first problem found reported.
///
/// ```json
/// {
///   "schemaVersion": 1,
///   "id": "ghostty",
///   "displayName": "Ghostty",
///   "bundleIdentifier": "com.mitchellh.ghostty",
///   "minimumVersion": "1.3",
///   "notes": "…",
///   "open": {"kind": "appleScript", "script": "ghostty.applescript", "command": "words"},
///   "focus": {"kind": "windowID"},
///   "keepsMinimumLifetime": false
/// }
/// ```
///
/// `open` may instead be `{"kind": "exec", "executable": "Contents/MacOS/x", "arguments":
/// ["start", "--", "{helper}", "{mode}", "{token}"]}`. `notes` and `keepsMinimumLifetime`
/// (default false) are optional.
extension TerminalDefinition {
  /// The keys a definition's top level may have.
  static let topLevelKeys: Set<String> = [
    "schemaVersion", "id", "displayName", "bundleIdentifier", "minimumVersion", "notes", "open",
    "focus", "keepsMinimumLifetime",
  ]
  /// The keys an `appleScript` open may have.
  static let appleScriptOpenKeys: Set<String> = ["kind", "script", "command"]
  /// The keys an `exec` open may have.
  static let execOpenKeys: Set<String> = ["kind", "executable", "arguments"]
  /// The keys `focus` may have.
  static let focusKeys: Set<String> = ["kind"]

  /// The longest id, in bytes.
  static let maximumIDLength = 32
  /// The longest display name, in characters.
  static let maximumDisplayNameLength = 64
  /// The longest bundle identifier, in bytes.
  static let maximumBundleIdentifierLength = 255
  /// The longest minimum version text, in bytes.
  static let maximumVersionLength = 32
  /// The longest `notes`, in bytes.
  static let maximumNotesLength = 1024
  /// The longest script file name, in bytes.
  static let maximumScriptNameLength = 64
  /// The suffix every script file name has.
  static let scriptSuffix = ".applescript"
  /// The longest executable path, in bytes.
  static let maximumExecutableLength = 1024
  /// The most `exec` arguments.
  static let maximumArguments = 64
  /// The longest `exec` argument, in bytes.
  static let maximumArgumentLength = 4096

  /// The bytes an id may hold.
  static let idBytes: Set<UInt8> = Set("abcdefghijklmnopqrstuvwxyz0123456789-".utf8)
  /// The bytes one dot-separated part of a bundle identifier may hold.
  static let bundleIdentifierBytes: Set<UInt8> = Set(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-".utf8)
  /// The bytes a script file name may hold.
  static let scriptNameBytes: Set<UInt8> = Set(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-".utf8)

  /// Whether `id` follows the definition id rule: `[a-z0-9-]`, 1–32 bytes, and not reserved
  /// (`iterm2` is code, not a definition). A launch request's terminal uses it (PLAN.md D38).
  public static func isValidID(_ id: String) -> Bool {
    (1...maximumIDLength).contains(id.utf8.count) && id.utf8.allSatisfy(idBytes.contains)
      && !reservedIDs.contains(id)
  }

  /// Reads a definition from a file's bytes, or throws the first problem found.
  public static func decode(_ data: Data) throws(TerminalDefinitionProblem) -> TerminalDefinition {
    guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
      throw .notJSON
    }
    guard let object = json as? [String: Any] else { throw .notAnObject }
    // `JSONSerialization` keeps one of two members with the same name: refuse them before
    // any value is read.
    switch JSONDuplicateNameScanner.scan(data) {
    case .unique: break
    case .duplicate(let key): throw .duplicateKey(key)
    case .malformed: throw .notJSON
    }
    try checkSchemaVersion(object["schemaVersion"])
    try refuseUnknownKeys(in: object, allowed: topLevelKeys, path: nil)
    let id = try text(object, "id")
    guard (1...maximumIDLength).contains(id.utf8.count), id.utf8.allSatisfy(idBytes.contains)
    else { throw .invalidID }
    guard !reservedIDs.contains(id) else { throw .reservedID(id) }
    let displayName = try text(object, "displayName")
    guard (1...maximumDisplayNameLength).contains(displayName.count),
      !displayName.unicodeScalars.contains(where: isControl)
    else { throw .invalidDisplayName }
    let bundleIdentifier = try text(object, "bundleIdentifier")
    guard isValidBundleIdentifier(bundleIdentifier) else { throw .invalidBundleIdentifier }
    let versionText = try text(object, "minimumVersion")
    guard versionText.utf8.count <= maximumVersionLength,
      let minimumVersion = TerminalVersion(versionText)
    else { throw .invalidMinimumVersion }
    let notes = try optionalText(object, "notes")
    if let notes {
      guard notes.utf8.count <= maximumNotesLength,
        !notes.unicodeScalars.contains(where: { isControl($0) && $0 != "\n" && $0 != "\t" })
      else { throw .invalidNotes }
    }
    let keepsMinimumLifetime = try optionalBoolean(object, "keepsMinimumLifetime") ?? false
    let open = try openMethod(try nestedObject(object, "open"))
    let focus = try focusKind(try nestedObject(object, "focus"))
    if focus != .app, case .exec = open { throw .focusNeedsAppleScript(focus) }
    return TerminalDefinition(
      id: id,
      displayName: displayName,
      bundleIdentifier: bundleIdentifier,
      minimumVersion: minimumVersion,
      notes: notes,
      open: open,
      focus: focus,
      keepsMinimumLifetime: keepsMinimumLifetime
    )
  } // End of static func decode(_:)

  /// Checks `schemaVersion`: present, a whole number, exactly `schemaVersion`.
  static func checkSchemaVersion(_ value: Any?) throws(TerminalDefinitionProblem) {
    guard let value else { throw .missingSchemaVersion }
    guard let version = wholeNumber(value) else {
      throw .wrongType(key: "schemaVersion", expected: .wholeNumber)
    }
    if version > schemaVersion { throw .newerSchemaVersion(version) }
    if version != schemaVersion { throw .unsupportedSchemaVersion(version) }
  }

  /// Throws `unknownKey` for the first key of `object` (in sorted order) not in `allowed`.
  static func refuseUnknownKeys(
    in object: [String: Any],
    allowed: Set<String>,
    path: String?
  ) throws(TerminalDefinitionProblem) {
    if let key = object.keys.sorted().first(where: { !allowed.contains($0) }) {
      throw .unknownKey(path.map { "\($0).\(key)" } ?? key)
    }
  }

  /// Reads the `open` object.
  static func openMethod(_ object: [String: Any]) throws(TerminalDefinitionProblem)
    -> TerminalOpenMethod
  {
    let kind = try text(object, "kind", path: "open")
    switch kind {
    case "appleScript":
      try refuseUnknownKeys(in: object, allowed: appleScriptOpenKeys, path: "open")
      let script = try text(object, "script", path: "open")
      guard isValidScriptName(script) else { throw .invalidScriptName }
      let form = try text(object, "command", path: "open")
      guard let command = TerminalCommandForm(rawValue: form) else { throw .unknownCommandForm }
      return .appleScript(script: script, command: command)
    case "exec":
      try refuseUnknownKeys(in: object, allowed: execOpenKeys, path: "open")
      let executable = try text(object, "executable", path: "open")
      guard isValidExecutable(executable) else { throw .invalidExecutable }
      guard let raw = object["arguments"] else { throw .missingKey("open.arguments") }
      guard let list = raw as? [Any] else {
        throw .wrongType(key: "open.arguments", expected: .list)
      }
      return .exec(executable: executable, arguments: try execArguments(list))
    default:
      throw .unknownOpenKind
    }
  } // End of static func openMethod(_:)

  /// Reads `open.arguments`: each literal or exactly one whole known placeholder, every
  /// placeholder exactly once.
  static func execArguments(_ list: [Any]) throws(TerminalDefinitionProblem)
    -> [TerminalExecArgument]
  {
    guard list.count <= maximumArguments else { throw .tooManyArguments(limit: maximumArguments) }
    var arguments: [TerminalExecArgument] = []
    for (index, item) in list.enumerated() {
      let position = index + 1
      guard let argument = item as? String else {
        throw .wrongType(key: "open.arguments item \(position)", expected: .text)
      }
      guard argument.utf8.count <= maximumArgumentLength,
        !argument.unicodeScalars.contains(where: isControl)
      else { throw .invalidArgument(position: position) }
      if let placeholder = TerminalPlaceholder.allCases.first(where: { $0.text == argument }) {
        arguments.append(.placeholder(placeholder))
      } else if argument.contains("{") || argument.contains("}") {
        let whole =
          argument.hasPrefix("{") && argument.hasSuffix("}") && argument.count >= 2
          && !argument.dropFirst().dropLast().contains(where: { $0 == "{" || $0 == "}" })
        throw whole
          ? .unknownPlaceholder(position: position) : .placeholderInsideArgument(position: position)
      } else {
        arguments.append(.literal(argument))
      }
    } // End of loop over the exec arguments
    for placeholder in TerminalPlaceholder.allCases
    where arguments.filter({ $0 == .placeholder(placeholder) }).count != 1 {
      throw .placeholderNotOnce(placeholder)
    }
    return arguments
  } // End of static func execArguments(_:)

  /// Reads the `focus` object.
  static func focusKind(_ object: [String: Any]) throws(TerminalDefinitionProblem)
    -> TerminalFocusKind
  {
    try refuseUnknownKeys(in: object, allowed: focusKeys, path: "focus")
    guard let kind = TerminalFocusKind(rawValue: try text(object, "kind", path: "focus")) else {
      throw .unknownFocusKind
    }
    return kind
  }

  // MARK: - Values

  /// The text at `key` (required).
  static func text(
    _ object: [String: Any],
    _ key: String,
    path: String? = nil
  ) throws(TerminalDefinitionProblem) -> String {
    let name = path.map { "\($0).\(key)" } ?? key
    guard let value = object[key] else { throw .missingKey(name) }
    guard let text = value as? String else { throw .wrongType(key: name, expected: .text) }
    return text
  }

  /// The text at `key`, or `nil` when the key is absent.
  static func optionalText(
    _ object: [String: Any],
    _ key: String
  ) throws(TerminalDefinitionProblem) -> String? {
    guard object[key] != nil else { return nil }
    return try text(object, key)
  }

  /// The boolean at `key`, or `nil` when the key is absent. A number is not a boolean.
  static func optionalBoolean(
    _ object: [String: Any],
    _ key: String
  ) throws(TerminalDefinitionProblem) -> Bool? {
    guard let value = object[key] else { return nil }
    guard let number = value as? NSNumber, isBoolean(number) else {
      throw .wrongType(key: key, expected: .boolean)
    }
    return number.boolValue
  }

  /// The object at `key` (required).
  static func nestedObject(
    _ object: [String: Any],
    _ key: String
  ) throws(TerminalDefinitionProblem) -> [String: Any] {
    guard let value = object[key] else { throw .missingKey(key) }
    guard let nested = value as? [String: Any] else {
      throw .wrongType(key: key, expected: .object)
    }
    return nested
  }

  /// `value` as a whole number: a JSON number that is not a boolean and has no fraction part.
  static func wholeNumber(_ value: Any) -> Int? {
    guard let number = value as? NSNumber, !isBoolean(number),
      !CFNumberIsFloatType(number as CFNumber)
    else { return nil }
    // A number too large for an `Int` must not wrap into a small one.
    let whole = number.intValue
    return NSNumber(value: whole) == number ? whole : nil
  }

  /// Whether `number` came from a JSON `true` or `false`.
  static func isBoolean(_ number: NSNumber) -> Bool {
    CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID()
  }

  // MARK: - Rules

  /// Whether `scalar` is a control character: C0, DEL or C1.
  static func isControl(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
  }

  /// A bundle identifier: 1–255 bytes, dot-separated non-empty parts of ASCII letters, digits
  /// and hyphens.
  static func isValidBundleIdentifier(_ text: String) -> Bool {
    guard (1...maximumBundleIdentifierLength).contains(text.utf8.count) else { return false }
    return text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
      !part.isEmpty && part.utf8.allSatisfy(bundleIdentifierBytes.contains)
    }
  }

  /// A script file name: 1–64 bytes of ASCII letters, digits, `.`, `_` and `-`, not starting
  /// with `.`, ending in `.applescript` with something before it. So it is a plain name in
  /// the definition's own folder: no `/`, no hidden file, never a definition (`.json`).
  static func isValidScriptName(_ name: String) -> Bool {
    (1...maximumScriptNameLength).contains(name.utf8.count)
      && name.utf8.allSatisfy(scriptNameBytes.contains)
      && !name.hasPrefix(".")
      && name.hasSuffix(scriptSuffix)
      && name.utf8.count > scriptSuffix.utf8.count
  }

  /// An executable path inside an app: 1–1024 bytes, relative (no leading `/`), no empty,
  /// `.` or `..` part, no control character.
  static func isValidExecutable(_ path: String) -> Bool {
    guard (1...maximumExecutableLength).contains(path.utf8.count), !path.hasPrefix("/"),
      !path.unicodeScalars.contains(where: isControl)
    else { return false }
    return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
      !$0.isEmpty && $0 != "." && $0 != ".."
    }
  }
} // End of extension TerminalDefinition
