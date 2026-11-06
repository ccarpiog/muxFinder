import Foundation

/// Why a command text for a terminal's shell cannot be built. `message` is English, sentence
/// case.
public enum TerminalCommandTextError: Error, Sendable, Hashable, LocalizedError {
  /// The helper path does not start with `/`, or is only `/`.
  case helperPathNotAbsolute
  /// The helper path holds `'`, `\`, `!` or a control character.
  case helperPathUnsafe
  /// An argument is empty or holds something other than ASCII letters, digits, `.`, `_`
  /// and `-`.
  case argumentUnsafe

  /// The user-facing explanation.
  public var message: String {
    switch self {
    case .helperPathNotAbsolute, .helperPathUnsafe:
      return "muxFinder can't open sessions in this terminal from where it is installed, "
        + "because the path to its helper contains a quote, a backslash, an exclamation mark "
        + "or a control character. Move muxFinder to /Applications and try again."
    case .argumentUnsafe:
      return "muxFinder couldn't prepare the command for this terminal."
    }
  } // End of var message

  /// `LocalizedError` conformance, so `localizedDescription` shows `message`.
  public var errorDescription: String? { message }
} // End of enum TerminalCommandTextError

/// The command text a terminal types into the user's own shell, such as Terminal.app's
/// `do script` (PLAN.md D3's extension, D38). That text is shell source for whatever shell the
/// user has (zsh, bash, fish, tcsh…), so it holds only `exec`, the helper path and fixed or
/// validated words, each POSIX single-quoted:
///
/// `exec '<helper path>' '<argument>' …`
///
/// The helper path is refused when it holds `'` or `\` (fish reads `\'` and `\\` inside single
/// quotes as escapes; POSIX shells do not), `!` (csh and tcsh expand history inside single
/// quotes) or a control character (a line break would end the command). Arguments are the
/// helper's constant mode words and a canonical launch id, so they must be non-empty ASCII
/// letters, digits, `.`, `_` and `-`. Every word is then read the same by every one of those
/// shells. `exec` replaces the user's shell with the helper, so nothing of the shell runs after
/// it.
public enum TerminalCommandText {
  /// The bytes an argument may hold.
  static let argumentBytes: Set<UInt8> = Set(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-".utf8)

  /// `exec`, then `helperPath` and every argument, each POSIX single-quoted, separated by one
  /// space. Throws when the path or an argument breaks the rules above.
  public static func shellCommand(
    helperPath: String,
    arguments: [String]
  ) throws(TerminalCommandTextError) -> String {
    try validateHelperPath(helperPath)
    for argument in arguments {
      guard !argument.isEmpty, argument.utf8.allSatisfy(argumentBytes.contains) else {
        throw .argumentUnsafe
      }
    }
    return (["exec"] + ([helperPath] + arguments).map(ShellQuoting.posixSingleQuote))
      .joined(separator: " ")
  } // End of static func shellCommand(helperPath:arguments:)

  /// Checks `path` against the helper path rules: absolute, longer than `/`, and no `'`, `\`,
  /// `!` or control character (C0, DEL or C1).
  public static func validateHelperPath(_ path: String) throws(TerminalCommandTextError) {
    guard path.hasPrefix("/"), path.count > 1 else { throw .helperPathNotAbsolute }
    for scalar in path.unicodeScalars {
      let value = scalar.value
      let isControl = value < 0x20 || (0x7F...0x9F).contains(value)
      if isControl || scalar == "'" || scalar == "\\" || scalar == "!" {
        throw .helperPathUnsafe
      }
    }
  } // End of static func validateHelperPath(_:)
} // End of enum TerminalCommandText
