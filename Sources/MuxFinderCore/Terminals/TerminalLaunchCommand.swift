import Foundation

/// Why a launch command for a terminal cannot be built from the helper path, mode word and
/// token (PLAN.md D38, Phase I-12b1). `message` is English, sentence case.
public enum TerminalLaunchCommandError: Error, Sendable, Hashable, LocalizedError {
  /// The helper path does not start with `/`, or is only `/`.
  case helperPathNotAbsolute
  /// For `shellText`: the helper path holds `'`, `\`, `!` or a control character (D3's
  /// extension, `TerminalCommandText`).
  case helperPathUnsafeForShellText
  /// For `words`: the helper path holds a space or another byte outside
  /// `TerminalLaunchCommand.wordBytes`.
  case helperPathUnsafeForWords
  /// For `exec`: the helper path holds a control character.
  case helperPathUnsafeForArguments
  /// The mode word or the token is empty or holds something other than ASCII letters,
  /// digits, `.`, `_` and `-`.
  case wordUnsafe

  /// The user-facing explanation.
  public var message: String {
    switch self {
    case .helperPathNotAbsolute, .helperPathUnsafeForShellText:
      return TerminalCommandTextError.helperPathUnsafe.message
    case .helperPathUnsafeForWords:
      return "muxFinder can't open sessions in this terminal from where it is installed, "
        + "because the path to its helper contains a space or a character other than "
        + "letters, digits, /, ., _, + and -. Move muxFinder to /Applications and try again."
    case .helperPathUnsafeForArguments:
      return "muxFinder can't open sessions in this terminal from where it is installed, "
        + "because the path to its helper contains a control character. "
        + "Move muxFinder to /Applications and try again."
    case .wordUnsafe:
      return TerminalCommandTextError.argumentUnsafe.message
    }
  } // End of var message

  /// `LocalizedError` conformance, so `localizedDescription` shows `message`.
  public var errorDescription: String? { message }
} // End of enum TerminalLaunchCommandError

/// The values a terminal's launch runs: the helper's absolute path, its constant mode word and
/// the launch token. They become an AppleScript open's four arguments
/// (`appleScriptArguments(form:)`) or an `exec` definition's argv (`execArgv(_:inApp:)`).
public struct TerminalLaunchCommand: Sendable, Hashable {
  /// The bytes each word of the `words` form may hold: D2's characters (ASCII letters, digits,
  /// `.`, `_`, `/`, `-`) plus `+`. No space, quote, `$` or glob character, so the words mean
  /// the same under every parsing a terminal's command may get (Ghostty's `command`: through
  /// `/bin/sh -c`, `direct:`, or guessed).
  public static let wordBytes: Set<UInt8> = Set(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/+-".utf8)

  /// The launch helper's absolute path.
  public let helperPath: String
  /// The helper's mode word.
  public let mode: String
  /// The launch token.
  public let token: String

  /// The command for `helperPath`, `mode` and `token`. The values are checked when a form is
  /// built.
  public init(helperPath: String, mode: String, token: String) {
    self.helperPath = helperPath
    self.mode = mode
    self.token = token
  }

  /// The four values `muxfinder_open(commandText, helperPath, modeWord, token)` receives
  /// (`TerminalScriptHandler.open`): for `shellText` the command text and three empty texts;
  /// for `words` an empty text and the three words.
  public func appleScriptArguments(
    form: TerminalCommandForm
  ) throws(TerminalLaunchCommandError) -> [String] {
    switch form {
    case .shellText:
      return [try shellText(), "", "", ""]
    case .words:
      try checkWords()
      return ["", helperPath, mode, token]
    }
  }

  /// D3's extension (`TerminalCommandText`): `exec '<helper>' '<mode>' '<token>'`.
  public func shellText() throws(TerminalLaunchCommandError) -> String {
    do throws(TerminalCommandTextError) {
      return try TerminalCommandText.shellCommand(helperPath: helperPath, arguments: [mode, token])
    } catch {
      switch error {
      case .helperPathNotAbsolute: throw .helperPathNotAbsolute
      case .helperPathUnsafe: throw .helperPathUnsafeForShellText
      case .argumentUnsafe: throw .wordUnsafe
      }
    }
  } // End of func shellText()

  /// Checks the `words` form: an absolute helper path of `wordBytes` only, and the mode word
  /// and token as `TerminalCommandText` words.
  func checkWords() throws(TerminalLaunchCommandError) {
    guard helperPath.hasPrefix("/"), helperPath.utf8.count > 1 else {
      throw .helperPathNotAbsolute
    }
    guard helperPath.utf8.allSatisfy(Self.wordBytes.contains) else {
      throw .helperPathUnsafeForWords
    }
    try checkModeAndToken()
  }

  /// Checks the mode word and the token: non-empty ASCII letters, digits, `.`, `_` and `-`.
  func checkModeAndToken() throws(TerminalLaunchCommandError) {
    for word in [mode, token] {
      guard !word.isEmpty, word.utf8.allSatisfy(TerminalCommandText.argumentBytes.contains)
      else { throw .wordUnsafe }
    }
  }

  /// The executable and argv an `exec` definition runs: `executable` resolved inside the app
  /// at `appURL` (the app LaunchServices found), every placeholder replaced by its value and
  /// every literal kept as written. Spawned with an argv, never through a shell, so the
  /// helper path only has to be absolute and free of control characters.
  public func execArgv(
    _ open: TerminalOpenMethod,
    inApp appURL: URL
  ) throws(TerminalLaunchCommandError) -> (executable: URL, arguments: [String])? {
    guard case .exec(let executable, let template) = open else { return nil }
    guard helperPath.hasPrefix("/"), helperPath.utf8.count > 1 else {
      throw .helperPathNotAbsolute
    }
    guard !helperPath.unicodeScalars.contains(where: TerminalDefinition.isControl) else {
      throw .helperPathUnsafeForArguments
    }
    try checkModeAndToken()
    let arguments = template.map { argument -> String in
      switch argument {
      case .literal(let text): return text
      case .placeholder(.helper): return helperPath
      case .placeholder(.mode): return mode
      case .placeholder(.token): return token
      }
    }
    return (appURL.appending(path: executable, directoryHint: .notDirectory), arguments)
  } // End of func execArgv(_:inApp:)
} // End of struct TerminalLaunchCommand
