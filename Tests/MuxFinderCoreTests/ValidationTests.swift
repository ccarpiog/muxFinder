import Foundation
import Testing

@testable import MuxFinderCore

/// Tests for every acceptance and rejection rule in `Validation`.
@Suite("Validation")
struct ValidationTests {
  // MARK: Session names

  /// Surrounding whitespace is trimmed; Unicode and inner spaces are fine.
  @Test(arguments: [
    ("  work  ", "work"),
    ("my session", "my session"),
    ("café", "café"),
    ("日本語のセッション", "日本語のセッション"),
    ("🧪 tests 👨‍👩‍👧", "🧪 tests 👨‍👩‍👧"),
    ("a-b_c+d@e", "a-b_c+d@e"),
  ])
  func acceptsSessionNames(input: String, expected: String) throws {
    #expect(try Validation.sessionName(input) == expected)
  }

  /// Exactly 100 characters (counted as characters, not bytes) is the limit.
  @Test func acceptsSessionNamesAtTheLengthLimit() throws {
    let ascii = String(repeating: "a", count: 100)
    let emoji = String(repeating: "👨‍👩‍👧", count: 100)
    #expect(try Validation.sessionName(ascii) == ascii)
    #expect(try Validation.sessionName(emoji) == emoji)
  }

  /// Every session-name rejection reason.
  @Test(arguments: [
    ("", ValidationError.sessionNameEmpty),
    ("   \n\t ", .sessionNameEmpty),
    ("a\u{7}b", .sessionNameContainsControlCharacter),
    ("tab\tinside", .sessionNameContainsControlCharacter),
    ("line\nbreak", .sessionNameContainsControlCharacter),
    ("escape\u{1B}[31m", .sessionNameContainsControlCharacter),
    ("c1\u{9B}control", .sessionNameContainsControlCharacter),
    ("nul\0byte", .sessionNameContainsControlCharacter),
    ("a:b", .sessionNameContainsColonOrPeriod),
    ("v1.2", .sessionNameContainsColonOrPeriod),
    (#"back\slash"#, .sessionNameContainsBackslash),
    ("-flag", .sessionNameStartsWithHyphen),
    ("  -flag", .sessionNameStartsWithHyphen),
    (String(repeating: "a", count: 101), .sessionNameTooLong(maximumLength: 100)),
    // A combining mark after the reserved byte makes another grapheme cluster, not another byte.
    ("a:\u{301}b", .sessionNameContainsColonOrPeriod),
    ("v1.\u{301}2", .sessionNameContainsColonOrPeriod),
    ("back\\\u{301}slash", .sessionNameContainsBackslash),
    ("-\u{301}flag", .sessionNameStartsWithHyphen),
  ])
  func rejectsSessionNames(input: String, expected: ValidationError) {
    #expect(throws: expected) { try Validation.sessionName(input) }
  }

  // MARK: SSH destinations

  /// Host names, aliases and user@host forms are accepted unchanged.
  @Test(arguments: ["saturno-m4", "user@host.example.com", "sirio-m5", "[::1]", "host:22"])
  func acceptsSSHDestinations(input: String) throws {
    #expect(try Validation.sshDestination(input) == input)
  }

  /// Every SSH-destination rejection reason.
  @Test(arguments: [
    ("", ValidationError.sshDestinationEmpty),
    ("two words", .sshDestinationContainsWhitespace),
    (" leading", .sshDestinationContainsWhitespace),
    ("no-break\u{A0}space", .sshDestinationContainsWhitespace),
    ("bell\u{7}", .sshDestinationContainsControlCharacter),
    ("host\n", .sshDestinationContainsControlCharacter),
    ("-oProxyCommand=evil", .sshDestinationStartsWithHyphen),
    ("-\u{301}oProxyCommand=evil", .sshDestinationStartsWithHyphen),
  ])
  func rejectsSSHDestinations(input: String, expected: ValidationError) {
    #expect(throws: expected) { try Validation.sshDestination(input) }
  }

  // MARK: Executable paths

  /// Absolute paths, including ones with spaces, are accepted unchanged.
  @Test(arguments: ["/opt/homebrew/bin/tmux", "/Applications/My Tools/tmux", "/usr/bin/ssh"])
  func acceptsExecutablePaths(input: String) throws {
    #expect(try Validation.executablePath(input) == input)
  }

  /// Every executable-path rejection reason.
  @Test(arguments: [
    ("", ValidationError.executablePathNotAbsolute),
    ("tmux", .executablePathNotAbsolute),
    ("./tmux", .executablePathNotAbsolute),
    ("~/bin/tmux", .executablePathNotAbsolute),
    (" /opt/homebrew/bin/tmux", .executablePathNotAbsolute),
    ("/opt/homebrew/bin/tmux\n", .executablePathContainsControlCharacter),
    ("/usr/bin/\u{7F}", .executablePathContainsControlCharacter),
  ])
  func rejectsExecutablePaths(input: String, expected: ValidationError) {
    #expect(throws: expected) { try Validation.executablePath(input) }
  }

  // MARK: Working directories

  /// Home-relative, absolute, relative and empty directories are accepted unchanged.
  @Test(arguments: ["", "~", "~/", "~/Projects/my dir", "/tmp", "relative/dir", "日本/🧪"])
  func acceptsWorkingDirectories(input: String) throws {
    #expect(try Validation.workingDirectory(input) == input)
  }

  /// Every working-directory rejection reason.
  @Test(arguments: [
    ("a\0b", ValidationError.workingDirectoryContainsNullCharacter),
    ("a\nb", .workingDirectoryContainsLineBreak),
    ("a\rb", .workingDirectoryContainsLineBreak),
    ("~/dir\r\n", .workingDirectoryContainsLineBreak),
  ])
  func rejectsWorkingDirectories(input: String, expected: ValidationError) {
    #expect(throws: expected) { try Validation.workingDirectory(input) }
  }

  // MARK: Persistent profile session names

  /// Each character tmux's target syntax reserves is refused in front of a default session
  /// name, also when a combining mark, an enclosing mark or a variation selector follows it:
  /// those make another grapheme cluster, but tmux still reads the reserved byte first.
  @Test(arguments: ["$", "=", "@", "%", "!", "~", "{", "+", "^"])
  func rejectsLeadingTargetCharacters(reserved: String) {
    for suffix in ["main", "\u{301}main", "\u{301}", "\u{20DD}x", "\u{FE0F}1", "\u{301}\u{302}"] {
      let name = reserved + suffix
      #expect(
        throws: ValidationError.sessionNameStartsWithTargetCharacter, "\(name.debugDescription)"
      ) {
        try Validation.persistentSessionName(name)
      }
    } // End of loop over the suffixes
  } // End of func rejectsLeadingTargetCharacters(reserved:)

  /// A reserved character after the first scalar, or a name starting with a combining mark or
  /// a decomposed letter, passes.
  @Test(arguments: ["main$", "a=b", "e\u{301}main", "\u{301}$x", "work #1"])
  func acceptsPersistentSessionNames(name: String) throws {
    #expect(try Validation.persistentSessionName(name) == name)
  }

  // MARK: Messages

  /// Every error has an English, sentence-case message exposed through `localizedDescription`.
  @Test(arguments: [
    ValidationError.sessionNameEmpty,
    .sessionNameTooLong(maximumLength: 100),
    .sessionNameContainsControlCharacter,
    .sessionNameContainsColonOrPeriod,
    .sessionNameContainsBackslash,
    .sessionNameStartsWithHyphen,
    .sshDestinationEmpty,
    .sshDestinationContainsWhitespace,
    .sshDestinationContainsControlCharacter,
    .sshDestinationStartsWithHyphen,
    .executablePathNotAbsolute,
    .executablePathContainsControlCharacter,
    .workingDirectoryContainsNullCharacter,
    .workingDirectoryContainsLineBreak,
    .sessionNameStartsWithTargetCharacter,
    .sessionNameNotTrimmed,
    .profileNameEmpty,
    .profileNameContainsControlCharacter,
  ])
  func hasUserFacingMessage(error: ValidationError) throws {
    let message = error.message
    let first = try #require(message.first)
    #expect(first.isUppercase)
    #expect(message.hasSuffix("."))
    #expect(error.localizedDescription == message)
  }

  /// The length limit appears in its message.
  @Test func tooLongMessageNamesTheLimit() {
    #expect(ValidationError.sessionNameTooLong(maximumLength: 100).message.contains("100"))
  }
}
