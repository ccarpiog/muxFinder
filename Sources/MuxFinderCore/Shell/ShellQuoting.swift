import Foundation

/// A shell script body that is a compile-time constant.
///
/// It can only be created from a string literal without interpolation (or by joining two such
/// scripts), so runtime values can never be spliced into shell source (PLAN.md D3). Data reaches
/// the script as positional parameters through `ShellQuoting.remoteCommand(script:args:)`.
public struct StaticShellScript: Sendable, Hashable, ExpressibleByStringLiteral {
  /// The script source.
  public let source: String

  /// Creates a script from a string literal.
  public init(stringLiteral value: StaticString) {
    source = value.description
  }

  /// Joins two static scripts; the result is still free of runtime data.
  public static func + (lhs: StaticShellScript, rhs: StaticShellScript) -> StaticShellScript {
    StaticShellScript(joining: lhs.source + rhs.source)
  }

  /// Creates a script from source that is already known to be static.
  private init(joining source: String) {
    self.source = source
  }
}

/// POSIX shell quoting and the remote-command builder (PLAN.md D3).
public enum ShellQuoting {
  /// The `$0` given to remote scripts.
  public static let scriptName = "muxfinder"

  /// Quotes `value` as one POSIX shell word: wraps it in single quotes and turns every `'` into
  /// `'\''`. Inside single quotes no character is special, so the shell yields the exact bytes.
  ///
  /// Shell words cannot carry NUL bytes; callers reject them first (the process runner refuses
  /// any argument that contains one).
  public static func posixSingleQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
  }

  /// Builds the single command string OpenSSH sends to the remote login shell:
  /// `/bin/sh -c '<script>' muxfinder '<arg1>' '<arg2>' …`.
  ///
  /// The login shell (zsh or bash, the macOS default) parses only quoted words, so `/bin/sh`
  /// receives the static script and every argument byte for byte. Inside the script the
  /// arguments are `"$1"`, `"$2"`, … and `$0` is `muxfinder`.
  public static func remoteCommand(script: StaticShellScript, args: [String]) -> String {
    let words = ["/bin/sh", "-c", posixSingleQuote(script.source), scriptName]
    return (words + args.map(posixSingleQuote)).joined(separator: " ")
  }
}
