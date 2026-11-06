import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// Terminal.app's command text (PLAN.md D3's extension, D38): `exec` and POSIX single-quoted
/// words, refused for a helper path a shell could read differently, and read the same by every
/// shell macOS ships (and fish when it is installed).
@Suite("Terminal command text")
struct TerminalCommandTextTests {
  /// A canonical launch id.
  static let token = "0f8fad5b-d9cb-469f-a165-70867728950e"

  /// The shells the text is run through, with options that skip their startup files.
  static let shells: [[String]] = [
    ["/bin/sh"], ["/bin/zsh", "-f"], ["/bin/bash", "--noprofile", "--norc"], ["/bin/dash"],
    ["/bin/ksh"], ["/bin/tcsh", "-f"], ["/bin/csh", "-f"],
    ["/opt/homebrew/bin/fish", "--no-config"], ["/usr/local/bin/fish", "--no-config"],
  ]

  /// The text is `exec` and each word single-quoted, separated by one space.
  @Test func buildsTheText() throws {
    let text = try TerminalCommandText.shellCommand(
      helperPath: "/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch",
      arguments: ["attach", Self.token])
    #expect(
      text
        == "exec '/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch' 'attach' '"
        + Self.token + "'")
    #expect(
      try TerminalCommandText.shellCommand(helperPath: "/a b/c", arguments: []) == "exec '/a b/c'")
  }

  /// A path with `'`, `\`, `!` or a control character is refused, as is one that is not
  /// absolute.
  @Test(arguments: [
    "/Apps/it's/muxfinder-launch", #"/Apps/a\b/muxfinder-launch"#, "/Apps/wow!/muxfinder-launch",
    "/Apps/a\nb/muxfinder-launch", "/Apps/a\tb", "/Apps/a\u{7F}b", "/Apps/a\u{85}b",
    "/Apps/a\u{9B}b", "/Apps/a\u{0}b", "/Apps/a\rb",
  ])
  func refusesUnsafeHelperPaths(path: String) {
    #expect(throws: TerminalCommandTextError.helperPathUnsafe) {
      try TerminalCommandText.shellCommand(helperPath: path, arguments: ["attach"])
    }
  }

  /// A relative path, an empty one or `/` alone is refused.
  @Test(arguments: ["", "/", "muxfinder-launch", "./muxfinder-launch", "~/muxfinder-launch"])
  func refusesPathsThatAreNotAbsolute(path: String) {
    #expect(throws: TerminalCommandTextError.helperPathNotAbsolute) {
      try TerminalCommandText.shellCommand(helperPath: path, arguments: [])
    }
  }

  /// An argument must be non-empty ASCII letters, digits, `.`, `_` and `-`.
  @Test(arguments: ["", "a b", "it's", "$HOME", "a;b", "é", "a\nb", "*"])
  func refusesUnsafeArguments(argument: String) {
    #expect(throws: TerminalCommandTextError.argumentUnsafe) {
      try TerminalCommandText.shellCommand(helperPath: "/bin/echo", arguments: [argument])
    }
  }

  /// The messages are user-facing English and name the fix.
  @Test func explainsTheRefusal() {
    #expect(TerminalCommandTextError.helperPathUnsafe.message.contains("/Applications"))
    #expect(
      TerminalCommandTextError.helperPathUnsafe.localizedDescription
        == TerminalCommandTextError.helperPathUnsafe.message)
  }

  /// Through every shell present, the text runs the helper (here a link to `/bin/echo` in a
  /// folder whose name holds spaces and characters every shell treats specially outside
  /// quotes) with exactly its arguments.
  @Test(arguments: shells)
  func everyShellReadsTheSameWords(shell: [String]) async throws {
    guard access(shell[0], X_OK) == 0 else { return }
    let folder = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let odd = folder.appending(path: #"a b $HOME;(x)`y` "q" * ~ # & | é{1,2}"#)
    try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: false)
    let helper = odd.appending(path: "echo").path(percentEncoded: false)
    try FileManager.default.createSymbolicLink(atPath: helper, withDestinationPath: "/bin/echo")
    let text = try TerminalCommandText.shellCommand(
      helperPath: helper, arguments: ["attach", "--plain", Self.token])
    let result = try await TestSupport.fastRunner.run(
      ProcessRequest(
        executableURL: URL(fileURLWithPath: shell[0]),
        arguments: Array(shell.dropFirst()) + ["-c", text],
        environment: TestSupport.environment.merging(["HOME": "/nonexistent-home"]) { $1 },
        timeout: .seconds(10)))
    #expect(result.termination == .exited(0), "\(shell[0])")
    #expect(
      String(decoding: result.standardOutput, as: UTF8.self) == "attach --plain \(Self.token)\n",
      "\(shell[0])")
  } // End of func everyShellReadsTheSameWords(shell:)
} // End of struct TerminalCommandTextTests
