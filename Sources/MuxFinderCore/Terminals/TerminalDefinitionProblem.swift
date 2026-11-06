import Foundation

/// Why a terminal definition file, or the folder holding it, cannot be used (PLAN.md D38,
/// Phase I-12b1). Every unusable file is kept with its problem and never stops the others from
/// loading. `message` is a plain English sentence in sentence case, for Settings; `code` is a
/// stable machine-readable name, for the probe and tests.
public enum TerminalDefinitionProblem: Error, Sendable, Hashable, CustomStringConvertible {
  /// Why a file is not used, whatever it contains (D19's rules for files read).
  public enum FileReason: String, Sendable, Hashable {
    /// It is a symbolic link (never followed).
    case symbolicLink
    /// It is not a regular file (a folder, a FIFO, a socket …).
    case notARegularFile
    /// Another user owns it.
    case notOwnedByUser
    /// Group or others may write to it.
    case writableByOthers
    /// It carries an extended access control list.
    case extendedACL
    /// It is larger than its limit.
    case tooLarge
    /// It is not there (a script the definition names, or a file gone since the folder was
    /// listed).
    case missing
    /// It could not be opened or read.
    case unreadable
  } // End of enum FileReason

  /// Why the user's terminals folder is not used: then none of its definitions is.
  public enum FolderReason: String, Sendable, Hashable {
    /// The folder, or a folder on its path, is a symbolic link.
    case symbolicLink
    /// Something other than a folder is at its path.
    case notAFolder
    /// Another user owns it.
    case notOwnedByUser
    /// Its mode is not 0700.
    case permissionsNotPrivate
    /// It carries an extended access control list.
    case extendedACL
    /// Its path is not absolute, or holds `.` or `..`.
    case notAPlainPath
    /// It is missing (only the built-in folder reports this; a missing user folder is fine).
    case missing
    /// It could not be opened or listed.
    case unreadable
  } // End of enum FolderReason

  /// The JSON type a key's value must have.
  public enum ValueType: String, Sendable, Hashable {
    /// A JSON string.
    case text
    /// A JSON number without a fraction.
    case wholeNumber
    /// `true` or `false`.
    case boolean
    /// A JSON object.
    case object
    /// A JSON array.
    case list
  }

  // MARK: Files and folders

  /// The definition file itself is not used.
  case unsafeFile(FileReason)
  /// The folder holding it is not used (one problem for the whole folder).
  case unsafeFolder(FolderReason)
  /// The folder holds more definition files than are read; this one is past the limit.
  case tooManyFiles(limit: Int)
  /// The definition's script file is not used.
  case unsafeScript(name: String, FileReason)
  /// The definition's script file is not UTF-8 text, or holds a NUL byte.
  case scriptNotText(name: String)

  // MARK: Contents

  /// The file is not valid JSON.
  case notJSON
  /// The file's JSON is not an object.
  case notAnObject
  /// The file has no `schemaVersion`.
  case missingSchemaVersion
  /// The file was written for a newer muxFinder, with this schema version.
  case newerSchemaVersion(Int)
  /// The file has a schema version no muxFinder reads (zero or negative).
  case unsupportedSchemaVersion(Int)
  /// The file has a key muxFinder does not know, at this path (such as `open.extra`).
  case unknownKey(String)
  /// The file has a member name twice in one object, at this path (such as `open.kind`), so
  /// which value counts would be ambiguous.
  case duplicateKey(String)
  /// The file lacks a required key, at this path.
  case missingKey(String)
  /// A key's value has the wrong JSON type.
  case wrongType(key: String, expected: ValueType)
  /// `id` breaks its rule.
  case invalidID
  /// `id` is reserved.
  case reservedID(String)
  /// `displayName` breaks its rule.
  case invalidDisplayName
  /// `bundleIdentifier` breaks its rule.
  case invalidBundleIdentifier
  /// `minimumVersion` is not a dotted decimal version.
  case invalidMinimumVersion
  /// `notes` is too long or holds a control character.
  case invalidNotes
  /// `open.kind` is neither `appleScript` nor `exec`.
  case unknownOpenKind
  /// `open.script` is not a plain `.applescript` file name.
  case invalidScriptName
  /// `open.command` is neither `shellText` nor `words`.
  case unknownCommandForm
  /// `open.executable` is not a relative path inside the app.
  case invalidExecutable
  /// `open.arguments` has more arguments than allowed.
  case tooManyArguments(limit: Int)
  /// An argument (counted from 1) is too long or holds a control character.
  case invalidArgument(position: Int)
  /// An argument (counted from 1) holds a placeholder, or a brace, inside longer text.
  case placeholderInsideArgument(position: Int)
  /// An argument (counted from 1) is a placeholder muxFinder does not know.
  case unknownPlaceholder(position: Int)
  /// A placeholder is missing from the arguments, or there more than once.
  case placeholderNotOnce(TerminalPlaceholder)
  /// `focus.kind` is not `tty`, `windowID` or `app`.
  case unknownFocusKind
  /// The focus kind needs an `appleScript` open.
  case focusNeedsAppleScript(TerminalFocusKind)
  /// Another file in the same folder has this id, so neither is used.
  case duplicateID(String)

  /// A stable, machine-readable name for the problem.
  public var code: String {
    switch self {
    case .unsafeFile(let reason): return "unsafeFile.\(reason.rawValue)"
    case .unsafeFolder(let reason): return "unsafeFolder.\(reason.rawValue)"
    case .tooManyFiles: return "tooManyFiles"
    case .unsafeScript(_, let reason): return "unsafeScript.\(reason.rawValue)"
    case .scriptNotText: return "scriptNotText"
    case .notJSON: return "notJSON"
    case .notAnObject: return "notAnObject"
    case .missingSchemaVersion: return "missingSchemaVersion"
    case .newerSchemaVersion: return "newerSchemaVersion"
    case .unsupportedSchemaVersion: return "unsupportedSchemaVersion"
    case .unknownKey: return "unknownKey"
    case .duplicateKey: return "duplicateKey"
    case .missingKey: return "missingKey"
    case .wrongType: return "wrongType"
    case .invalidID: return "invalidID"
    case .reservedID: return "reservedID"
    case .invalidDisplayName: return "invalidDisplayName"
    case .invalidBundleIdentifier: return "invalidBundleIdentifier"
    case .invalidMinimumVersion: return "invalidMinimumVersion"
    case .invalidNotes: return "invalidNotes"
    case .unknownOpenKind: return "unknownOpenKind"
    case .invalidScriptName: return "invalidScriptName"
    case .unknownCommandForm: return "unknownCommandForm"
    case .invalidExecutable: return "invalidExecutable"
    case .tooManyArguments: return "tooManyArguments"
    case .invalidArgument: return "invalidArgument"
    case .placeholderInsideArgument: return "placeholderInsideArgument"
    case .unknownPlaceholder: return "unknownPlaceholder"
    case .placeholderNotOnce: return "placeholderNotOnce"
    case .unknownFocusKind: return "unknownFocusKind"
    case .focusNeedsAppleScript: return "focusNeedsAppleScript"
    case .duplicateID: return "duplicateID"
    }
  } // End of var code

  /// The user-facing explanation: a plain English sentence about the file (or its folder).
  public var message: String {
    switch self {
    case .unsafeFile(let reason): return Self.fileMessage(reason, subject: "This file")
    case .unsafeFolder(let reason): return Self.folderMessage(reason)
    case .tooManyFiles(let limit):
      return "muxFinder reads at most \(limit) terminal definitions from a folder, "
        + "and this file is past that limit."
    case .unsafeScript(let name, let reason):
      return Self.fileMessage(reason, subject: "Its script \(name)")
    case .scriptNotText(let name):
      return "Its script \(name) isn't UTF-8 text."
    case .notJSON: return "This file isn't valid JSON."
    case .notAnObject: return "This file doesn't hold a JSON object."
    case .missingSchemaVersion: return "This file has no schemaVersion."
    case .newerSchemaVersion(let version):
      return "This file was written for a newer version of muxFinder (schemaVersion \(version))."
    case .unsupportedSchemaVersion(let version):
      return "This file's schemaVersion \(version) isn't one muxFinder reads."
    case .unknownKey(let key):
      return "This file has a key muxFinder doesn't know: \(Self.printable(key))."
    case .duplicateKey(let key):
      return "This file has the key \(Self.printable(key)) more than once."
    case .missingKey(let key): return "This file has no \(key)."
    case .wrongType(let key, let expected):
      return "In this file, \(key) must be \(Self.typeName(expected))."
    case .invalidID:
      return "Its id must be 1 to 32 lowercase letters, digits or hyphens."
    case .reservedID(let id):
      return "Its id \(id) is reserved, because muxFinder supports that terminal itself."
    case .invalidDisplayName:
      return "Its displayName must be 1 to 64 characters with no control characters."
    case .invalidBundleIdentifier:
      return "Its bundleIdentifier must be words of letters, digits and hyphens joined by dots."
    case .invalidMinimumVersion:
      return "Its minimumVersion must be numbers joined by dots, such as 1.3."
    case .invalidNotes:
      return "Its notes must be at most 1 KB, with no control characters except line breaks."
    case .unknownOpenKind: return "Its open kind must be appleScript or exec."
    case .invalidScriptName:
      return "Its script must be a plain file name ending in .applescript, "
        + "in the same folder as the definition."
    case .unknownCommandForm: return "Its open command must be shellText or words."
    case .invalidExecutable:
      return "Its executable must be a path inside the app, "
        + "with no leading slash and no . or .. parts."
    case .tooManyArguments(let limit):
      return "Its arguments may hold at most \(limit) items."
    case .invalidArgument(let position):
      return "Its argument \(position) is too long or has a control character."
    case .placeholderInsideArgument(let position):
      return "Its argument \(position) has a placeholder or a brace inside other text. "
        + "A placeholder must be a whole argument."
    case .unknownPlaceholder(let position):
      return "Its argument \(position) is a placeholder muxFinder doesn't know. "
        + "The placeholders are {helper}, {mode} and {token}."
    case .placeholderNotOnce(let placeholder):
      return "Its arguments must have \(placeholder.text) exactly once."
    case .unknownFocusKind: return "Its focus kind must be tty, windowID or app."
    case .focusNeedsAppleScript(let kind):
      return "Its focus kind \(kind.rawValue) needs an appleScript open. Use app with exec."
    case .duplicateID(let id):
      return "Another definition in the same folder also has the id \(id), "
        + "so muxFinder uses neither."
    }
  } // End of var message

  /// The same as `message`.
  public var description: String { message }

  /// The sentence for a file `reason`, about `subject` ("This file", "Its script x").
  static func fileMessage(_ reason: FileReason, subject: String) -> String {
    switch reason {
    case .symbolicLink: return "\(subject) is a symbolic link, so muxFinder doesn't use it."
    case .notARegularFile: return "\(subject) isn't a regular file."
    case .notOwnedByUser: return "\(subject) belongs to another user."
    case .writableByOthers: return "Other users can change \(lowercased(subject))."
    case .extendedACL:
      return "\(subject) has an access control list, so other users might be able to change it."
    case .tooLarge: return "\(subject) is too large."
    case .missing: return "\(subject) is missing."
    case .unreadable: return "muxFinder couldn't read \(lowercased(subject))."
    }
  } // End of static func fileMessage(_:subject:)

  /// The sentence for a folder `reason`.
  static func folderMessage(_ reason: FolderReason) -> String {
    switch reason {
    case .symbolicLink:
      return "The terminals folder, or a folder on its path, is a symbolic link, "
        + "so muxFinder doesn't use the definitions in it."
    case .notAFolder: return "Something other than a folder is where the terminals folder goes."
    case .notOwnedByUser: return "The terminals folder belongs to another user."
    case .permissionsNotPrivate:
      return "Other users have access to the terminals folder. Its mode must be 0700."
    case .extendedACL:
      return "The terminals folder has an access control list, "
        + "so other users might have access to it."
    case .notAPlainPath: return "The terminals folder's path isn't a plain absolute path."
    case .missing: return "The folder of muxFinder's own terminal definitions is missing."
    case .unreadable: return "muxFinder couldn't read the terminals folder."
    }
  } // End of static func folderMessage(_:)

  /// `subject` with its first letter lowercased, for use inside a sentence ("this file").
  static func lowercased(_ subject: String) -> String {
    guard let first = subject.first else { return subject }
    return first.lowercased() + subject.dropFirst()
  }

  /// The article and name of a JSON type.
  static func typeName(_ type: ValueType) -> String {
    switch type {
    case .text: return "text"
    case .wholeNumber: return "a whole number"
    case .boolean: return "true or false"
    case .object: return "an object"
    case .list: return "a list"
    }
  }

  /// `key` as shown in a message: at most 64 characters, control characters replaced by `?`.
  static func printable(_ key: String) -> String {
    let cleaned = String(
      String.UnicodeScalarView(
        key.unicodeScalars.map { TerminalDefinition.isControl($0) ? "?" : $0 }))
    return cleaned.count > 64 ? String(cleaned.prefix(64)) + "…" : cleaned
  }
} // End of enum TerminalDefinitionProblem
