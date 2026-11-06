import Foundation
import Testing

@testable import MuxFinderCore

/// `FolderSearchText` (PLAN.md D36): the pure escaping of typed folder-name text and its
/// limits, and the query line built from it. Synthetic text only.
@Suite("Folder search text")
struct FolderSearchTextTests {
  /// The escaped text of `text`, failing the test when it is refused.
  static func escaped(_ text: String) throws -> String {
    try FolderSearchText.nameText(for: text).escaped
  }

  /// The issue `text` is refused with, or `nil` when it is accepted.
  static func issue(_ text: String) -> FolderSearchTextIssue? {
    do throws(FolderSearchTextIssue) {
      _ = try FolderSearchText.nameText(for: text)
      return nil
    } catch {
      return error
    }
  }

  /// Backslash, quote, star and question mark get a backslash; everything else is kept.
  @Test func escapesTheFourSpecialCharacters() throws {
    #expect(try Self.escaped(#"a\b"#) == #"a\\b"#)
    #expect(try Self.escaped(#"a"b"#) == #"a\"b"#)
    #expect(try Self.escaped("a*b") == #"a\*b"#)
    #expect(try Self.escaped("a?b") == #"a\?b"#)
    #expect(try Self.escaped(#"\"*?"#) == #"\\\"\*\?"#)
    #expect(try Self.escaped(#"x\\"#) == #"x\\\\"#)
    #expect(
      try Self.escaped("it's $HOME `x` (y) [z] {w} ; | & < > ~ # %")
        == "it's $HOME `x` (y) [z] {w} ; | & < > ~ # %")
  } // End of func escapesTheFourSpecialCharacters()

  /// Leading, trailing and inner whitespace stay: they are part of a name.
  @Test func keepsWhitespace() throws {
    #expect(try Self.escaped("  ab  ") == "  ab  ")
    #expect(try Self.escaped("a b") == "a b")
    #expect(try Self.escaped("  ") == "  ")
  }

  /// Diacritics and other scripts are kept as typed (the predicate's `cd` handles them); a
  /// star with a combining mark is still escaped, because escaping works on scalars.
  @Test func keepsDiacriticsAndEscapesScalars() throws {
    #expect(try Self.escaped("café") == "café")
    #expect(try Self.escaped("cafe\u{301}") == "cafe\u{301}")
    #expect(try Self.escaped("日本") == "日本")
    #expect(try Self.escaped("a*\u{301}") == "a\\*\u{301}")
    #expect(try Self.escaped("\"\u{301}x") == "\\\"\u{301}x")
  }

  /// Fewer than 2 characters is too short; an accented letter typed as two scalars is one
  /// character.
  @Test func needsTwoCharacters() throws {
    #expect(Self.issue("") == .tooShort)
    #expect(Self.issue("a") == .tooShort)
    #expect(Self.issue("e\u{301}") == .tooShort)
    #expect(Self.issue("🇪🇸") == .tooShort)
    #expect(Self.issue("ab") == nil)
    #expect(Self.issue("e\u{301}x") == nil)
  }

  /// C0, DEL, C1 and the line and paragraph separators refuse the query.
  @Test func refusesControlCharacters() {
    for scalar in [
      "\u{0}", "\u{1}", "\t", "\n", "\r", "\u{1B}", "\u{1F}", "\u{7F}", "\u{80}",
      "\u{85}", "\u{9F}", "\u{2028}", "\u{2029}",
    ] {
      #expect(
        Self.issue("ab\(scalar)cd") == .controlCharacter, "\(scalar.unicodeScalars.first!.value)")
    } // End of loop over control characters
    #expect(Self.issue("ab\u{A0}cd") == nil)
    #expect(Self.issue("ab\u{200B}cd") == nil)
  } // End of func refusesControlCharacters()

  /// More than 255 bytes of UTF-8 is too long, counted before escaping.
  @Test func boundsTheLength() throws {
    #expect(Self.issue(String(repeating: "a", count: 255)) == nil)
    #expect(Self.issue(String(repeating: "a", count: 256)) == .tooLong)
    #expect(Self.issue(String(repeating: "é", count: 127) + "a") == nil)
    #expect(Self.issue(String(repeating: "é", count: 128)) == .tooLong)
    let stars = try Self.escaped(String(repeating: "*", count: 255))
    #expect(stars.utf8.count == 510)
    #expect(stars.utf8.count <= FolderSearchScript.maximumNameTextLength)
  }

  /// The query line is `<id> <scope> <name text>` and a line feed.
  @Test func buildsTheQueryLine() throws {
    let name = try FolderSearchText.nameText(for: " a*b ")
    let line = FolderSearchScript.queryLine(id: 42, scope: .disk, name: name)
    #expect(String(decoding: line, as: UTF8.self) == "42 disk  a\\*b \n")
    let home = FolderSearchScript.queryLine(
      id: 1, scope: .home, name: try FolderSearchText.nameText(for: "do"))
    #expect(String(decoding: home, as: UTF8.self) == "1 home do\n")
  }

  /// Issue codes and messages are stable and hold no text.
  @Test func issuesHaveCodes() {
    #expect(FolderSearchTextIssue.tooShort.code == "tooShort")
    #expect(FolderSearchTextIssue.controlCharacter.code == "controlCharacter")
    #expect(FolderSearchTextIssue.tooLong.code == "tooLong")
    #expect(!FolderSearchTextIssue.tooLong.message.isEmpty)
  }
}
