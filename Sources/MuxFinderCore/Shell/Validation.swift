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
  /// (tmux rewrites them), a leading `-`, and more than `maximumSessionNameLength` characters.
  public static func sessionName(_ raw: String) throws(ValidationError) -> String {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw .sessionNameEmpty }
    guard !containsControlCharacter(name) else { throw .sessionNameContainsControlCharacter }
    guard !name.contains(":"), !name.contains(".") else {
      throw .sessionNameContainsColonOrPeriod
    }
    guard !name.hasPrefix("-") else { throw .sessionNameStartsWithHyphen }
    guard name.count <= maximumSessionNameLength else {
      throw .sessionNameTooLong(maximumLength: maximumSessionNameLength)
    }
    return name
  } // End of func sessionName(_:)

  /// Validates an SSH destination (a host name, `user@host` or an `~/.ssh/config` alias) and
  /// returns it unchanged. Rejected: empty, any whitespace, control characters, a leading `-`.
  public static func sshDestination(_ raw: String) throws(ValidationError) -> String {
    guard !raw.isEmpty else { throw .sshDestinationEmpty }
    guard !containsControlCharacter(raw) else { throw .sshDestinationContainsControlCharacter }
    guard !raw.unicodeScalars.contains(where: \.properties.isWhitespace) else {
      throw .sshDestinationContainsWhitespace
    }
    guard !raw.hasPrefix("-") else { throw .sshDestinationStartsWithHyphen }
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
