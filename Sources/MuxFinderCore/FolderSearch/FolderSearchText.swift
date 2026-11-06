import Foundation

/// Where a folder search looks on its host (PLAN.md D36): the home folder (`mdfind -onlyin
/// "$HOME"`) or the whole disk (every volume Spotlight indexes). Stored in `preferences.json` as
/// its raw value (D32); `home` when the file holds none.
public enum FolderSearchScope: String, Sendable, Hashable, CaseIterable, Codable {
  /// The host's home folder and everything below it.
  case home
  /// Every volume Spotlight indexes on the host.
  case disk

  /// The scope a host searches when no preference says otherwise.
  public static let standard: FolderSearchScope = .home
}

/// Why typed text cannot be sent as a folder search (PLAN.md D36). Too short text is no
/// problem the user needs to hear about: nothing is searched yet.
public enum FolderSearchTextIssue: Error, Sendable, Hashable {
  /// Fewer than `FolderSearchText.minimumCharacters` characters.
  case tooShort
  /// A control character (C0, DEL, C1) or a line or paragraph separator.
  case controlCharacter
  /// More than `FolderSearchText.maximumUTF8Length` bytes of UTF-8, which no folder name has.
  case tooLong

  /// A stable, machine-readable name.
  public var code: String {
    switch self {
    case .tooShort: return "tooShort"
    case .controlCharacter: return "controlCharacter"
    case .tooLong: return "tooLong"
    }
  }

  /// The user-facing explanation, in English and sentence case.
  public var message: String {
    switch self {
    case .tooShort: return "Type at least 2 characters to search folders."
    case .controlCharacter: return "Folder names can't contain control characters or line breaks."
    case .tooLong: return "Folder names can't be that long."
    }
  }
}

/// Typed text made safe for the folder-search script's name predicate (PLAN.md D36): the only
/// way to build one is `FolderSearchText.nameText(for:)`, so a query line can never carry text
/// that was not escaped.
public struct FolderSearchNameText: Sendable, Hashable {
  /// The escaped text, as it goes between `*` and `*` in `kMDItemFSName == "*<text>*"cd`.
  public let escaped: String

  /// Wraps text `FolderSearchText` escaped.
  fileprivate init(escaped: String) {
    self.escaped = escaped
  }
}

/// The pure escaping of typed folder-name text for Spotlight's query syntax (PLAN.md D36).
///
/// Spotlight reads a quoted value with backslash escapes, and `*` and `?` in it are wildcards.
/// So the scalars `\`, `"`, `*` and `?` are each written with a backslash in front, which makes
/// them match themselves (verified on this Mac against `mdfind` by counts, D36). Everything else
/// is kept as typed, leading and trailing whitespace included (a folder name may have it); case
/// and diacritics are left to the predicate's `cd` modifier. Text is refused when it has fewer than
/// `minimumCharacters` characters (`Character`s, so an accented letter typed as two scalars
/// counts once), a control character (C0, DEL, C1, U+2028, U+2029) or more than
/// `maximumUTF8Length` bytes of UTF-8 (a folder name's maximum), before escaping.
public enum FolderSearchText {
  /// The fewest characters a search needs.
  public static let minimumCharacters = 2
  /// The most bytes of UTF-8 typed text may have: a folder name's maximum length.
  public static let maximumUTF8Length = 255
  /// The scalars escaped with a backslash. Escaping works on scalars, not `Character`s, so a
  /// `*` that carries a combining mark is still escaped.
  public static let escapedScalars: Set<Unicode.Scalar> = ["\\", "\"", "*", "?"]

  /// The escaped name text for `text`, or why it cannot be searched.
  public static func nameText(
    for text: String
  ) throws(FolderSearchTextIssue) -> FolderSearchNameText {
    guard text.count >= minimumCharacters else { throw .tooShort }
    guard !text.unicodeScalars.contains(where: isRefused) else { throw .controlCharacter }
    guard text.utf8.count <= maximumUTF8Length else { throw .tooLong }
    var escaped = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      if escapedScalars.contains(scalar) { escaped.append("\\") }
      escaped.append(scalar)
    }
    return FolderSearchNameText(escaped: String(escaped))
  } // End of static func nameText(for:)

  /// Whether `scalar` refuses a query: C0 controls, DEL, C1 controls and the line and paragraph
  /// separators.
  public static func isRefused(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029: return true
    default: return false
    }
  }
}
