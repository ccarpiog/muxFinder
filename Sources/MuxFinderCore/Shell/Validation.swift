import Foundation

/// Why a user-supplied value was rejected. `message` is the English, sentence-case text shown
/// in the UI.
public enum ValidationError: Error, Sendable, Hashable, LocalizedError {
  /// The session name is empty after trimming whitespace.
  case sessionNameEmpty
  /// The session name is longer than `maximumLength` characters.
  case sessionNameTooLong(maximumLength: Int)
  /// The session name contains a control character (including line breaks and tabs).
  case sessionNameContainsControlCharacter
  /// The session name contains `:` or `.`, which tmux silently replaces.
  case sessionNameContainsColonOrPeriod
  /// The session name contains `\`, which tmux stores doubled (`\\`), so the session would
  /// get another name than the one asked for.
  case sessionNameContainsBackslash
  /// The session name starts with `-`, which tmux would read as an option.
  case sessionNameStartsWithHyphen
  /// The SSH destination is empty.
  case sshDestinationEmpty
  /// The SSH destination contains whitespace.
  case sshDestinationContainsWhitespace
  /// The SSH destination contains a control character.
  case sshDestinationContainsControlCharacter
  /// The SSH destination starts with `-`, which ssh would read as an option.
  case sshDestinationStartsWithHyphen
  /// The executable path does not start with `/`.
  case executablePathNotAbsolute
  /// The executable path contains a control character.
  case executablePathContainsControlCharacter
  /// The working directory contains a NUL character.
  case workingDirectoryContainsNullCharacter
  /// The working directory contains a line break.
  case workingDirectoryContainsLineBreak
  /// A persistent profile's default session name starts with a character tmux's target syntax
  /// gives a meaning (`$`, `=`, `@`, `%`, `!`, `~`, `{`, `+`, `^`), so `new-session -A` could
  /// attach another session than the one named (PLAN.md D26).
  case sessionNameStartsWithTargetCharacter
  /// A stored session name starts or ends with whitespace, which a typed one would have lost
  /// (`sessionName(_:)` trims), so it is not the name tmux would get.
  case sessionNameNotTrimmed
  /// The iTerm2 profile name is empty.
  case profileNameEmpty
  /// The iTerm2 profile name contains a control character.
  case profileNameContainsControlCharacter

  /// The user-facing explanation.
  public var message: String {
    switch self {
    case .sessionNameEmpty:
      return "Enter a session name."
    case .sessionNameTooLong(let maximumLength):
      return "Session names can be at most \(maximumLength) characters long."
    case .sessionNameContainsControlCharacter:
      return "Session names can't contain line breaks, tabs or other control characters."
    case .sessionNameContainsColonOrPeriod:
      return "Session names can't contain “:” or “.” because tmux replaces them."
    case .sessionNameContainsBackslash:
      return "Session names can't contain “\\” because tmux changes it."
    case .sessionNameStartsWithHyphen:
      return "Session names can't start with “-”."
    case .sshDestinationEmpty:
      return "Enter an SSH destination, such as a host name or user@host."
    case .sshDestinationContainsWhitespace:
      return "SSH destinations can't contain spaces."
    case .sshDestinationContainsControlCharacter:
      return "SSH destinations can't contain control characters."
    case .sshDestinationStartsWithHyphen:
      return "SSH destinations can't start with “-”."
    case .executablePathNotAbsolute:
      return "Enter a full path that starts with “/”, such as /opt/homebrew/bin/tmux."
    case .executablePathContainsControlCharacter:
      return "Executable paths can't contain control characters."
    case .workingDirectoryContainsNullCharacter:
      return "Working directories can't contain null characters."
    case .workingDirectoryContainsLineBreak:
      return "Working directories can't contain line breaks."
    case .sessionNameStartsWithTargetCharacter:
      return "Default session names can't start with “$”, “=”, “@”, “%”, “!”, “~”, “{”, “+” "
        + "or “^”."
    case .sessionNameNotTrimmed:
      return "Session names can't start or end with spaces."
    case .profileNameEmpty:
      return "Enter a profile name."
    case .profileNameContainsControlCharacter:
      return "Profile names can't contain line breaks, tabs or other control characters."
    }
  } // End of var message

  /// `LocalizedError` conformance, so `localizedDescription` shows `message`.
  public var errorDescription: String? { message }
}

/// Checks for values the user types (session names, SSH destinations, paths) before they reach
/// tmux, ssh or the file system. Each check returns the value to use, or throws a
/// `ValidationError`.
public enum Validation {
  /// The longest accepted session name, in characters.
  public static let maximumSessionNameLength = 100

  /// Validates a tmux session name and returns it trimmed of surrounding whitespace.
  ///
  /// Unicode (accents, CJK, emoji) is allowed. Rejected: empty, control characters, `:` or `.`
  /// (tmux rewrites them), `\` (tmux stores it doubled), a leading `-`, and more than
  /// `maximumSessionNameLength` characters. A `#` is allowed: tmux expands formats in a new
  /// session's name, so `TmuxCommands` doubles every `#` before it reaches tmux (PLAN.md D18).
  /// Every check is on Unicode scalars, the bytes tmux reads, not on `Character`s: a combining
  /// mark after `:` or `-` makes another grapheme cluster but leaves the ASCII byte in place.
  public static func sessionName(_ raw: String) throws(ValidationError) -> String {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw .sessionNameEmpty }
    guard !containsControlCharacter(name) else { throw .sessionNameContainsControlCharacter }
    guard !name.unicodeScalars.contains(":"), !name.unicodeScalars.contains(".") else {
      throw .sessionNameContainsColonOrPeriod
    }
    guard !name.unicodeScalars.contains("\\") else { throw .sessionNameContainsBackslash }
    guard name.unicodeScalars.first != "-" else { throw .sessionNameStartsWithHyphen }
    guard name.count <= maximumSessionNameLength else {
      throw .sessionNameTooLong(maximumLength: maximumSessionNameLength)
    }
    return name
  } // End of func sessionName(_:)

  /// The first characters a persistent profile's default session name may not start with:
  /// tmux's target syntax reads them as an id (`$`, `@`, `%`), an exact or mouse target (`=`),
  /// the marked pane (`~`), a token (`{`), the last window (`!`) or an offset (`+`, `^`). All
  /// are ASCII, so each is one Unicode scalar and one byte.
  public static let targetSyntaxCharacters: Set<Unicode.Scalar> = [
    "$", "=", "@", "%", "!", "~", "{", "+", "^",
  ]

  /// Validates the default session name of a host's persistent profile (PLAN.md D26) and
  /// returns it trimmed: `sessionName(_:)`'s rules, plus no leading character from
  /// `targetSyntaxCharacters`. The profile runs `tmux new-session -A -s <name>`, and when a
  /// session with that name exists tmux attaches it through a target lookup of its name, which
  /// gives those first characters a meaning of their own. The check is on the first Unicode
  /// scalar, the first byte tmux reads, not on the first `Character`: a combining mark after
  /// `$` makes another grapheme cluster but leaves the `$` byte in front.
  public static func persistentSessionName(_ raw: String) throws(ValidationError) -> String {
    let name = try sessionName(raw)
    if let first = name.unicodeScalars.first, targetSyntaxCharacters.contains(first) {
      throw .sessionNameStartsWithTargetCharacter
    }
    return name
  } // End of func persistentSessionName(_:)

  /// Validates an iTerm2 profile name (a persistent profile's parent, PLAN.md D26) and returns
  /// it unchanged. Rejected: empty, or any control character.
  public static func profileName(_ raw: String) throws(ValidationError) -> String {
    guard !raw.isEmpty else { throw .profileNameEmpty }
    guard !containsControlCharacter(raw) else { throw .profileNameContainsControlCharacter }
    return raw
  }

  /// Validates an SSH destination (a host name, `user@host` or an `~/.ssh/config` alias) and
  /// returns it unchanged. Rejected: empty, any whitespace, control characters, a leading `-`
  /// (checked on the first Unicode scalar, so a combining mark after it does not hide it).
  public static func sshDestination(_ raw: String) throws(ValidationError) -> String {
    guard !raw.isEmpty else { throw .sshDestinationEmpty }
    guard !containsControlCharacter(raw) else { throw .sshDestinationContainsControlCharacter }
    guard !raw.unicodeScalars.contains(where: \.properties.isWhitespace) else {
      throw .sshDestinationContainsWhitespace
    }
    guard raw.unicodeScalars.first != "-" else { throw .sshDestinationStartsWithHyphen }
    return raw
  }

  /// Validates an executable path (for example a tmux override) and returns it unchanged.
  /// It must be absolute and free of control characters.
  public static func executablePath(_ raw: String) throws(ValidationError) -> String {
    guard raw.hasPrefix("/") else { throw .executablePathNotAbsolute }
    guard !containsControlCharacter(raw) else { throw .executablePathContainsControlCharacter }
    return raw
  }

  /// Validates a working directory and returns it unchanged. Rejected: NUL and line breaks.
  ///
  /// A leading `~/` is allowed and kept as is. It is expanded on the target host by the static
  /// script, from `$HOME`, never by splicing it into shell source.
  public static func workingDirectory(_ raw: String) throws(ValidationError) -> String {
    guard !raw.unicodeScalars.contains("\0") else { throw .workingDirectoryContainsNullCharacter }
    guard !raw.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else {
      throw .workingDirectoryContainsLineBreak
    }
    return raw
  }

  /// Whether `value` contains a Unicode control character (general category Cc: C0, DEL and
  /// C1). Format characters such as the zero-width joiner in emoji sequences are allowed.
  static func containsControlCharacter(_ value: String) -> Bool {
    value.unicodeScalars.contains { $0.properties.generalCategory == .control }
  }
}
