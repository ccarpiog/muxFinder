import Foundation
import Testing
import os

@testable import MuxFinderCore

/// The AppleScript runner seam and the handler contract (PLAN.md D38, Phase I-12b1). The real
/// runner compiles only the test scripts below, none with a `tell` block, so no app's
/// dictionary is read and nothing is launched; the built-in scripts are never compiled here.
@Suite("AppleScript runner")
@MainActor
struct AppleScriptRunnerTests {
  /// Handlers echoing their arguments.
  static let echoScript = TerminalScript(
    name: "echo.applescript",
    source: """
      on muxfinder_open(commandText, helperPath, modeWord, token)
      \treturn {commandText, helperPath, modeWord, token}
      end muxfinder_open
      on muxfinder_focus(windowID, ttyName)
      \treturn {windowID, ttyName}
      end muxfinder_focus
      on muxfinder_close(windowID)
      \treturn windowID
      end muxfinder_close
      """)

  /// Handlers answering the contract's shapes: an open reply whose window id is the mode word
  /// (so tests see which form arrived), and nothing.
  static let contractScript = TerminalScript(
    name: "contract.applescript",
    source: """
      on muxfinder_open(commandText, helperPath, modeWord, token)
      \treturn {modeWord, "/dev/ttys004"}
      end muxfinder_open
      on muxfinder_focus(windowID, ttyName)
      \treturn
      end muxfinder_focus
      on muxfinder_close(windowID)
      \treturn
      end muxfinder_close
      """)

  /// Handlers answering the wrong shapes, or raising errors.
  static let wrongScript = TerminalScript(
    name: "wrong.applescript",
    source: """
      on muxfinder_open(commandText, helperPath, modeWord, token)
      \treturn 42
      end muxfinder_open
      on muxfinder_focus(windowID, ttyName)
      \tset answer to "not nothing"
      end muxfinder_focus
      on muxfinder_close(windowID)
      \terror "The window still runs a process." number 1001
      end muxfinder_close
      """)

  /// Compiles `script` with the real runner.
  func compile(_ script: TerminalScript) throws(AppleScriptRunnerError) -> any CompiledAppleScript {
    try NSAppleScriptRunner().compile(script)
  }

  /// The failure `body` throws, or `nil`.
  func failure<T>(_ body: () throws(AppleScriptRunnerError) -> T) -> AppleScriptRunnerError? {
    do throws(AppleScriptRunnerError) {
      _ = try body()
      return nil
    } catch {
      return error
    }
  }

  /// The failure a contract call throws, or `nil`.
  func callFailure<T>(_ body: () throws(TerminalScriptCallError) -> T) -> TerminalScriptCallError? {
    do throws(TerminalScriptCallError) {
      _ = try body()
      return nil
    } catch {
      return error
    }
  }

  // MARK: - The real runner

  /// A handler receives its arguments as plain values: quotes, AppleScript syntax and
  /// non-ASCII text come back unchanged, never read as source.
  @Test func passesArgumentsAsValues() throws {
    let script = try compile(Self.echoScript)
    #expect(script.name == "echo.applescript")
    let arguments = [
      "exec '/Apps/x' 'attach-plain' 'id'", "\" & (do shell script \"echo no\") & \"",
      "end muxfinder_open\nreturn 1", "ü 日本 👩‍💻",
    ]
    #expect(try script.call(.open, arguments: arguments) == .list(arguments.map { .text($0) }))
    #expect(try script.call(.focus, arguments: ["", ""]) == .list([.text(""), .text("")]))
    #expect(try script.call(.close, arguments: ["7"]) == .text("7"))
    // Compiled once, called again.
    #expect(try script.call(.close, arguments: ["8"]) == .text("8"))
  } // End of func passesArgumentsAsValues()

  /// A bare `return` is nothing; a last statement's value or a number is something else.
  @Test func readsTypedReplies() throws {
    let contract = try compile(Self.contractScript)
    #expect(try contract.call(.focus, arguments: ["1", "/dev/ttys001"]) == .nothing)
    #expect(try contract.call(.close, arguments: ["1"]) == .nothing)
    let wrong = try compile(Self.wrongScript)
    #expect(try wrong.call(.open, arguments: ["", "", "", ""]) == .other(type: "long"))
    #expect(try wrong.call(.focus, arguments: ["", ""]) == .text("not nothing"))
  }

  /// A raised error comes back with its number; a missing handler is -1708; a wrong number of
  /// arguments is refused before any event; a script that does not compile is -2741.
  @Test func reportsFailuresWithTheirNumbers() throws {
    let wrong = try compile(Self.wrongScript)
    #expect(
      failure { () throws(AppleScriptRunnerError) in try wrong.call(.close, arguments: ["1"]) }
        == .callFailed(handler: .close, errorNumber: 1001))
    let partial = try compile(
      TerminalScript(
        name: "partial.applescript",
        source: "on muxfinder_open(a, b, c, d)\n\treturn {\"\", \"\"}\nend muxfinder_open\n"))
    #expect(
      failure { () throws(AppleScriptRunnerError) in
        try partial.call(.focus, arguments: ["", ""])
      } == .callFailed(handler: .focus, errorNumber: -1708))
    #expect(
      failure { () throws(AppleScriptRunnerError) in try partial.call(.open, arguments: [""]) }
        == .wrongArgumentCount(handler: .open))
    let broken = failure { () throws(AppleScriptRunnerError) in
      try self.compile(TerminalScript(name: "broken.applescript", source: "on x(\n\treturn {"))
    }
    #expect(broken == .compileFailed(errorNumber: -2741))
    #expect(broken?.errorNumber == -2741)
    #expect(AppleScriptRunnerError.wrongArgumentCount(handler: .close).errorNumber == nil)
  } // End of func reportsFailuresWithTheirNumbers()

  /// The error number is read whether `NSAppleScript` gives it as a number or as text.
  @Test func readsErrorNumbersInEitherForm() {
    #expect(
      NSAppleScriptRunner.errorNumber(in: [NSAppleScript.errorNumber: NSNumber(value: -1743)])
        == -1743)
    #expect(NSAppleScriptRunner.errorNumber(in: [NSAppleScript.errorNumber: "-1708"]) == -1708)
    #expect(NSAppleScriptRunner.errorNumber(in: [:]) == -2700)
    #expect(NSAppleScriptRunner.errorNumber(in: nil) == -2700)
    #expect(NSAppleScriptRunner.fourCharacterCode(0x6C6F_6E67) == "long")
    #expect(NSAppleScriptRunner.fourCharacterCode(0x0000_0001) == "????")
  }

  // MARK: - The contract

  /// The open reply is read strictly: two texts, empty ones `nil`, a tty only as `/dev/…`.
  @Test func readsOpenRepliesStrictly() {
    #expect(
      TerminalScriptCalls.openReply(from: .list([.text("4711"), .text("/dev/ttys004")]))
        == TerminalOpenReply(windowID: "4711", tty: "/dev/ttys004"))
    #expect(
      TerminalScriptCalls.openReply(from: .list([.text("B1F0-…"), .text("")]))
        == TerminalOpenReply(windowID: "B1F0-…", tty: nil))
    #expect(
      TerminalScriptCalls.openReply(from: .list([.text(""), .text("")]))
        == TerminalOpenReply(windowID: nil, tty: nil))
    let refused: [AppleScriptValue] = [
      .nothing, .text("4711"), .list([]), .list([.text("1")]),
      .list([.text("1"), .text("/dev/ttys1"), .text("x")]),
      .list([.other(type: "long"), .text("")]),
      .list([.text("1"), .nothing]), .list([.text("1"), .text("ttys004")]),
      .list([.text("1"), .text("/dev/")]), .list([.text("1"), .text("/dev/../etc/x")]),
      .list([.text("1"), .text("/dev/ttys 4")]), .list([.text("a\nb"), .text("")]),
      .list([.text(String(repeating: "9", count: 257)), .text("")]),
      .list([.list([.text("1")]), .text("")]),
    ]
    for value in refused {
      #expect(TerminalScriptCalls.openReply(from: value) == nil, "\(value)")
    }
  } // End of func readsOpenRepliesStrictly()

  /// The contract over the real runner and a test script: open, focus and close in each form.
  @Test func callsTheContractOverTheRealRunner() throws {
    let calls = TerminalScriptCalls(script: try compile(Self.contractScript), form: .words)
    // The test script answers {modeWord, "/dev/ttys004"}: the words form passes the mode word.
    let launch = TerminalLaunchCommand(
      helperPath: "/x/muxfinder-launch",
      mode: "attach-plain", token: "0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9")
    #expect(
      try calls.open(launch) == TerminalOpenReply(windowID: "attach-plain", tty: "/dev/ttys004"))
    let shell = TerminalScriptCalls(script: calls.script, form: .shellText)
    #expect(try shell.open(launch) == TerminalOpenReply(windowID: nil, tty: "/dev/ttys004"))
    #expect(
      callFailure { () throws(TerminalScriptCallError) in try calls.focus(windowID: "1", tty: nil) }
        == nil)
    #expect(
      callFailure { () throws(TerminalScriptCallError) in try calls.close(windowID: "1") } == nil)
    let wrong = TerminalScriptCalls(script: try compile(Self.wrongScript), form: .shellText)
    let command = TerminalLaunchCommand(helperPath: "/x/y", mode: "m", token: "t")
    #expect(
      callFailure { () throws(TerminalScriptCallError) in try wrong.open(command) }
        == .unexpectedReply(handler: .open))
    #expect(
      callFailure { () throws(TerminalScriptCallError) in try wrong.focus(windowID: "", tty: "") }
        == .unexpectedReply(handler: .focus))
    #expect(
      callFailure { () throws(TerminalScriptCallError) in try wrong.close(windowID: "1") }
        == .runner(
          .callFailed(handler: .close, errorNumber: TerminalScriptCalls.windowBusyErrorNumber)))
  } // End of func callsTheContractOverTheRealRunner()

  // MARK: - The fake

  /// The fake records compiles and calls with the contract's arguments for each form, and
  /// plays queued replies before its fallbacks.
  @Test func fakeRecordsCallsAndPlaysReplies() throws {
    let runner = FakeAppleScriptRunner()
    let token = "0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9"
    let helper = "/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch"
    let catalog = TerminalDefinitionTestSupport.load(
      builtIn: TerminalDefinitionTestSupport.builtInDirectory)
    let terminal = try TerminalScriptCalls.compile(
      try #require(catalog.definition(withID: "terminal")), with: runner)
    let ghostty = try TerminalScriptCalls.compile(
      try #require(catalog.definition(withID: "ghostty")), with: runner)
    #expect(runner.compiled == ["terminal.applescript", "ghostty.applescript"])
    runner.queued[.open] = [.success(.list([.text("4711"), .text("/dev/ttys004")]))]
    let command = TerminalLaunchCommand(helperPath: helper, mode: "attach-plain", token: token)
    #expect(try terminal.open(command) == TerminalOpenReply(windowID: "4711", tty: "/dev/ttys004"))
    #expect(try ghostty.open(command) == TerminalOpenReply(windowID: nil, tty: nil))
    try terminal.focus(windowID: "4711", tty: "/dev/ttys004")
    try ghostty.close(windowID: "W-1")
    #expect(
      runner.calls == [
        .init(
          script: "terminal.applescript", handler: .open,
          arguments: ["exec '\(helper)' 'attach-plain' '\(token)'", "", "", ""]),
        .init(
          script: "ghostty.applescript", handler: .open,
          arguments: ["", helper, "attach-plain", token]),
        .init(
          script: "terminal.applescript", handler: .focus, arguments: ["4711", "/dev/ttys004"]),
        .init(script: "ghostty.applescript", handler: .close, arguments: ["W-1"]),
      ])
    runner.queued[.close] = [.failure(.callFailed(handler: .close, errorNumber: -1728))]
    #expect(
      callFailure { () throws(TerminalScriptCallError) in try ghostty.close(windowID: "W-1") }
        == .runner(
          .callFailed(handler: .close, errorNumber: TerminalScriptCalls.windowNotFoundErrorNumber)))
    #expect(
      callFailure { () throws(TerminalScriptCallError) in try ghostty.close(windowID: "W-1") }
        == nil)
  } // End of func fakeRecordsCallsAndPlaysReplies()

  /// A launch command the form refuses never reaches the script; an `exec` definition has no
  /// handlers; a compile failure is passed on.
  @Test func refusesBeforeCalling() throws {
    let runner = FakeAppleScriptRunner()
    let catalog = TerminalDefinitionTestSupport.load(
      builtIn: TerminalDefinitionTestSupport.builtInDirectory)
    let ghostty = try TerminalScriptCalls.compile(
      try #require(catalog.definition(withID: "ghostty")), with: runner)
    let spaced = TerminalLaunchCommand(
      helperPath: "/Users/test/My Apps/muxfinder-launch",
      mode: "attach-plain", token: "t")
    #expect(
      callFailure { () throws(TerminalScriptCallError) in try ghostty.open(spaced) }
        == .launchCommand(.helperPathUnsafeForWords))
    #expect(runner.calls.isEmpty)
    let exec = LoadedTerminalDefinition(
      definition: try TerminalDefinition.decode(
        try TerminalDefinitionTestSupport.data(TerminalDefinitionTestSupport.execObject())),
      source: .user, fileName: "x.json", script: nil)
    #expect(
      callFailure { () throws(TerminalScriptCallError) in
        try TerminalScriptCalls.compile(exec, with: runner)
      } == .notAppleScript)
    runner.compileFailure = .compileFailed(errorNumber: -2741)
    let terminal = try #require(catalog.definition(withID: "terminal"))
    #expect(
      callFailure { () throws(TerminalScriptCallError) in
        try TerminalScriptCalls.compile(terminal, with: runner)
      } == .runner(.compileFailed(errorNumber: -2741)))
  } // End of func refusesBeforeCalling()
} // End of struct AppleScriptRunnerTests

/// Per-definition app facts over a fake inspector (PLAN.md D38): the version against the
/// minimum, the permission read only for `appleScript` definitions.
@Suite("Terminal app facts")
struct TerminalAppFactsTests {
  /// An inspector answering fixed values and counting permission reads.
  final class FakeInspector: TerminalAppInspecting {
    /// The snapshot answered.
    let fixedSnapshot: TerminalAppSnapshot
    /// The status answered.
    let status: Int32
    /// The bundle identifiers whose permission was read.
    let reads = OSAllocatedUnfairLock<[String]>(initialState: [])

    /// An inspector answering `snapshot` and `status`.
    init(_ snapshot: TerminalAppSnapshot, status: Int32 = 0) {
      fixedSnapshot = snapshot
      self.status = status
    }

    /// The fixed snapshot.
    func snapshot(bundleIdentifier: String) -> TerminalAppSnapshot { fixedSnapshot }

    /// The fixed status, recording the read.
    func automationStatus(bundleIdentifier: String) -> Int32 {
      reads.withLock { $0.append(bundleIdentifier) }
      return status
    }
  } // End of class FakeInspector

  /// A definition decoded from `object`.
  static func definition(_ object: [String: Any]) throws -> TerminalDefinition {
    try TerminalDefinition.decode(try TerminalDefinitionTestSupport.data(object))
  }

  /// An installed app at `version` with `minimumVersion` 1.0.
  static let app = URL(fileURLWithPath: "/Applications/Sample.app", isDirectory: true)

  /// The version check: meets, too old, unknown (unreadable or missing), not installed.
  @Test @MainActor func checksTheVersion() throws {
    let definition = try Self.definition(TerminalDefinitionTestSupport.appleScriptObject())
    /// The facts for `definition` with an inspector answering `snapshot`.
    func check(_ snapshot: TerminalAppSnapshot) -> TerminalAppFacts {
      TerminalAppFacts.read(for: definition, inspector: FakeInspector(snapshot, status: -600))
    }
    let meets = check(TerminalAppSnapshot(url: Self.app, version: "1.0.1", running: true))
    #expect(meets.versionCheck == .meets)
    #expect(meets.installed && meets.running)
    #expect(meets.path == "/Applications/Sample.app")
    #expect(meets.version == "1.0.1")
    #expect(
      check(TerminalAppSnapshot(url: Self.app, version: "0.9", running: false)).versionCheck
        == .tooOld)
    #expect(
      check(TerminalAppSnapshot(url: Self.app, version: "1.0 (tip)", running: false))
        .versionCheck == .unknown)
    #expect(
      check(TerminalAppSnapshot(url: Self.app, version: nil, running: false)).versionCheck
        == .unknown)
    let missing = check(TerminalAppSnapshot(url: nil, version: nil, running: false))
    #expect(missing.versionCheck == .notInstalled)
    #expect(!missing.installed && missing.path == nil)
  } // End of func checksTheVersion()

  /// The permission is read for `appleScript` definitions, never for `exec` ones.
  @Test @MainActor func readsThePermissionOnlyWhenNeeded() throws {
    let snapshot = TerminalAppSnapshot(url: Self.app, version: "1.0", running: true)
    let inspector = FakeInspector(snapshot, status: -1744)
    let apple = TerminalAppFacts.read(
      for: try Self.definition(TerminalDefinitionTestSupport.appleScriptObject()),
      inspector: inspector)
    #expect(apple.automation == .permission(.notDetermined, status: -1744))
    #expect(apple.automation.kind == "notDetermined")
    #expect(apple.automation.status == -1744)
    #expect(inspector.reads.withLock { $0 } == ["com.example.sample-terminal"])
    let exec = TerminalAppFacts.read(
      for: try Self.definition(TerminalDefinitionTestSupport.execObject()), inspector: inspector)
    #expect(exec.automation == .notNeeded)
    #expect(exec.automation.kind == "notNeeded")
    #expect(exec.automation.status == nil)
    #expect(inspector.reads.withLock { $0 }.count == 1)
  } // End of func readsThePermissionOnlyWhenNeeded()

  /// The real inspector finds no app for an identifier nobody uses (a read of LaunchServices
  /// only: nothing is launched and no event is sent).
  @Test @MainActor func realInspectorReadsOnly() {
    let snapshot = WorkspaceTerminalAppInspector().snapshot(
      bundleIdentifier: "test.muxfinder.no-such-terminal-app")
    #expect(snapshot == TerminalAppSnapshot(url: nil, version: nil, running: false))
    #expect(WorkspaceTerminalAppInspector.displayPath(Self.app) == "/Applications/Sample.app")
  }
} // End of struct TerminalAppFactsTests
