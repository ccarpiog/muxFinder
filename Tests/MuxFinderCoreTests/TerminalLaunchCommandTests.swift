import Foundation
import Testing

@testable import MuxFinderCore

/// The launch command's forms for terminal definitions (PLAN.md D38, Phase I-12b1): D3's shell
/// text, the `words` form and its limits, and argv expansion for `exec` definitions.
@Suite("Terminal launch command")
struct TerminalLaunchCommandTests {
  /// A canonical launch token.
  static let token = "0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9"
  /// An installed helper path.
  static let helper = "/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch"

  /// The command for `helper`, the mode word `attach-plain` and `token`.
  static func command(
    helper: String = helper, mode: String = "attach-plain",
    token: String = token
  ) -> TerminalLaunchCommand {
    TerminalLaunchCommand(helperPath: helper, mode: mode, token: token)
  }

  /// The error building `form` for `command` throws, or `nil`.
  static func error(_ command: TerminalLaunchCommand, _ form: TerminalCommandForm)
    -> TerminalLaunchCommandError?
  {
    do throws(TerminalLaunchCommandError) {
      _ = try command.appleScriptArguments(form: form)
      return nil
    } catch {
      return error
    }
  }

  /// `shellText` is D3's extension, in the first argument; the other three are empty.
  @Test func buildsShellText() throws {
    let arguments = try Self.command().appleScriptArguments(form: .shellText)
    #expect(
      arguments == [
        "exec '\(Self.helper)' 'attach-plain' '\(Self.token)'", "", "", "",
      ])
    // A folder name with spaces and shell characters is quoted, not refused, in this form.
    let spaced = Self.command(helper: "/Users/test/My Apps $(x)/muxFinder.app/muxfinder-launch")
    #expect(
      try spaced.shellText()
        == "exec '/Users/test/My Apps $(x)/muxFinder.app/muxfinder-launch' 'attach-plain' '\(Self.token)'"
    )
    #expect(
      Self.error(Self.command(helper: "/Users/it's/x"), .shellText) == .helperPathUnsafeForShellText
    )
    #expect(Self.error(Self.command(helper: "relative/x"), .shellText) == .helperPathNotAbsolute)
    #expect(Self.error(Self.command(mode: "attach plain"), .shellText) == .wordUnsafe)
  } // End of func buildsShellText()

  /// `words` passes an empty text and the three words as they are.
  @Test func buildsWords() throws {
    #expect(
      try Self.command().appleScriptArguments(form: .words)
        == ["", Self.helper, "attach-plain", Self.token])
    let plus = Self.command(
      helper: "/Users/test/Apps+Tools/muxFinder_2.app/Contents/MacOS/muxfinder-launch")
    #expect(try plus.appleScriptArguments(form: .words)[1] == plus.helperPath)
  }

  /// A `words` helper path outside D2's characters plus `+` (a space above all) is refused
  /// with a clear error, so the command means the same however the terminal parses it.
  @Test(arguments: [
    " ", "'", "\"", "$", "~", "*", "?", ";", "&", "|", "(", "!", "\\", "#", "=",
    "é", "\t", "%", ",", ":", "@", "{", "[",
  ])
  func refusesWordsOutsideTheCharacterSet(character: String) {
    let command = Self.command(helper: "/Users/test/Apps\(character)/muxfinder-launch")
    #expect(Self.error(command, .words) == .helperPathUnsafeForWords)
  }

  /// The `words` error says what is wrong and what to do; relative paths and bad words are
  /// refused too.
  @Test func wordsErrorsAreClear() {
    let message = TerminalLaunchCommandError.helperPathUnsafeForWords.message
    #expect(message.contains("contains a space"))
    #expect(message.contains("Move muxFinder to /Applications"))
    #expect(Self.error(Self.command(helper: "muxfinder-launch"), .words) == .helperPathNotAbsolute)
    #expect(Self.error(Self.command(helper: "/"), .words) == .helperPathNotAbsolute)
    for (mode, token) in [
      ("", Self.token), ("attach-plain", ""), ("attach/plain", Self.token),
      ("attach-plain", Self.token + " x"), ("attach+plain", Self.token),
    ] {
      #expect(Self.error(Self.command(mode: mode, token: token), .words) == .wordUnsafe)
    }
  } // End of func wordsErrorsAreClear()

  /// An `exec` definition's argv: the executable inside the app, placeholders replaced by
  /// whole values (a helper path with spaces or shell characters stays one argument), literals
  /// kept as written.
  @Test func expandsExecArguments() throws {
    let definition = try TerminalDefinition.decode(
      try TerminalDefinitionTestSupport.data(TerminalDefinitionTestSupport.execObject()))
    let app = URL(fileURLWithPath: "/Applications/Sample Terminal.app", isDirectory: true)
    let helper = "/Users/test/My Apps $(x) 'q'/muxFinder.app/Contents/MacOS/muxfinder-launch"
    let argv = try #require(try Self.command(helper: helper).execArgv(definition.open, inApp: app))
    #expect(
      argv.executable.path(percentEncoded: false)
        == "/Applications/Sample Terminal.app/Contents/MacOS/sample-terminal")
    #expect(
      argv.arguments == [
        "start", "--always-new-process", "--", helper, "attach-plain", Self.token,
      ])
    let reordered = TerminalOpenMethod.exec(
      executable: "Contents/MacOS/x",
      arguments: [
        .placeholder(.token), .literal(""), .placeholder(.helper), .literal("{literal"),
        .placeholder(.mode),
      ])
    #expect(
      try Self.command().execArgv(reordered, inApp: app)?.arguments == [
        Self.token, "", Self.helper, "{literal", "attach-plain",
      ])
  } // End of func expandsExecArguments()

  /// `exec` expansion refuses a relative helper path, a control character in it, and bad
  /// words; an `appleScript` open has no argv.
  @Test func execExpansionRefusals() throws {
    let open = TerminalOpenMethod.exec(
      executable: "Contents/MacOS/x",
      arguments: [.placeholder(.helper), .placeholder(.mode), .placeholder(.token)])
    let app = URL(fileURLWithPath: "/Applications/X.app", isDirectory: true)
    /// The error expanding `open` for `command` throws, or `nil`.
    func error(_ command: TerminalLaunchCommand) -> TerminalLaunchCommandError? {
      do throws(TerminalLaunchCommandError) {
        _ = try command.execArgv(open, inApp: app)
        return nil
      } catch {
        return error
      }
    }
    #expect(error(Self.command(helper: "relative")) == .helperPathNotAbsolute)
    #expect(error(Self.command(helper: "/a\nb")) == .helperPathUnsafeForArguments)
    #expect(error(Self.command(helper: "/a\u{0}b")) == .helperPathUnsafeForArguments)
    #expect(error(Self.command(token: "$(x)")) == .wordUnsafe)
    #expect(error(Self.command()) == nil)
    #expect(
      try Self.command().execArgv(
        .appleScript(script: "a.applescript", command: .words),
        inApp: app) == nil)
  } // End of func execExpansionRefusals()
} // End of struct TerminalLaunchCommandTests
