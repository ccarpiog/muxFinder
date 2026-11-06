import Foundation
import Testing

@testable import MuxFinderCore

/// The plain window layer (PLAN.md D38, Phase I-12b3): open, focus and close of a terminal
/// app's window from a definition, over `FakeAppleScriptRunner`, a fake app inspector, a fake
/// spawner and a fake activator. The built-in definitions are loaded as text and driven
/// through the fake runner only: no script is compiled, no Apple event sent, no app launched.
@Suite("Plain terminal windows")
@MainActor
struct PlainTerminalWindowsTests {
  /// Shorthand.
  typealias Definitions = TerminalDefinitionTestSupport

  /// The helper path every open passes.
  static let helper = "/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch"
  /// The launch token every open passes.
  static let token = LaunchToken("0f1e2d3c-4b5a-4978-8695-a4b3c2d1e0f9")!
  /// The environment an `exec` program gets.
  static let environment = ["HOME": "/Users/fixture", "PATH": "/usr/bin:/bin"]
  /// Where the fake inspector finds every app.
  static let app = URL(fileURLWithPath: "/Applications/Sample Terminal.app", isDirectory: true)

  /// The layer and its fakes.
  struct Harness {
    /// The AppleScript runner.
    let runner: FakeAppleScriptRunner
    /// The app inspector.
    let inspector: FakeTerminalAppInspector
    /// The spawner.
    let spawner: FakeTerminalProcessSpawner
    /// The activator.
    let activator: FakeTerminalAppActivator
    /// The layer.
    let windows: PlainTerminalWindows
  }

  /// A harness whose inspector finds the app at `app` with `version`, running or not, and
  /// reads the permission as `status` (granted by default).
  static func harness(
    version: String?,
    installed: Bool = true,
    running: Bool = true,
    status: Int32 = AutomationPermission.grantedStatus
  ) -> Harness {
    let runner = FakeAppleScriptRunner()
    let inspector = FakeTerminalAppInspector(
      snapshot: TerminalAppSnapshot(
        url: installed ? app : nil, version: version, running: running),
      status: status)
    let spawner = FakeTerminalProcessSpawner()
    let activator = FakeTerminalAppActivator()
    let windows = PlainTerminalWindows(
      runner: runner, inspector: inspector, spawner: spawner, activator: activator,
      environment: environment)
    return Harness(
      runner: runner, inspector: inspector, spawner: spawner, activator: activator,
      windows: windows)
  } // End of static func harness(version:installed:running:status:)

  /// The built-in definition `id`, loaded as text from the repository's `Resources/Terminals/`.
  static func builtIn(_ id: String) throws -> LoadedTerminalDefinition {
    try #require(Definitions.load(builtIn: Definitions.builtInDirectory).definition(withID: id))
  }

  /// The test `exec` definition (`sample-exec`, focus `app`, minimum 20240203).
  static func execDefinition() throws -> LoadedTerminalDefinition {
    LoadedTerminalDefinition(
      definition: try TerminalDefinition.decode(try Definitions.data(Definitions.execObject())),
      source: .user, fileName: "sample-exec.json", script: nil)
  }

  /// The failure `body` throws, or `nil` when it returns.
  static func failure<Value>(
    _ body: () throws(PlainTerminalWindowError) -> Value
  ) -> PlainTerminalWindowError? {
    do throws(PlainTerminalWindowError) {
      _ = try body()
      return nil
    } catch {
      return error
    }
  } // End of static func failure(_:)

  /// `muxfinder_open`'s reply with `windowID` and `tty` (empty for unknown).
  static func openReply(_ windowID: String, _ tty: String) -> AppleScriptValue {
    .list([.text(windowID), .text(tty)])
  }

  // MARK: - Open

  /// Terminal (`shellText`): the facts are read, the script compiled once, and
  /// `muxfinder_open` gets D3's command text with the mode word `attach-plain` and the token,
  /// the other three arguments empty; the reply becomes the window.
  @Test func opensTerminalWithItsShellText() throws {
    let terminal = try Self.builtIn("terminal")
    let harness = Self.harness(version: "2.15")
    harness.runner.queued[.open] = [.success(Self.openReply("4711", "/dev/ttys004"))]
    let window = try harness.windows.open(terminal, helperPath: Self.helper, token: Self.token)
    #expect(
      window
        == PlainTerminalWindow(openedBy: terminal, windowID: "4711", tty: "/dev/ttys004"))
    #expect(harness.runner.compiled == ["terminal.applescript"])
    #expect(
      harness.runner.calls == [
        .init(
          script: "terminal.applescript", handler: .open,
          arguments: ["exec '\(Self.helper)' 'attach-plain' '\(Self.token.rawValue)'", "", "", ""])
      ])
    #expect(LaunchHelperMode.attachPlain.word == "attach-plain")
    #expect(harness.inspector.snapshotReads == ["com.apple.Terminal"])
    #expect(harness.inspector.permissionReads == ["com.apple.Terminal"])
    #expect(harness.spawner.requests.isEmpty && harness.activator.requests.isEmpty)
    #expect(harness.windows.recordedWindows == [.init(openedBy: terminal, windowID: "4711")])
  } // End of func opensTerminalWithItsShellText()

  /// Ghostty (`words`): `muxfinder_open` gets an empty command text, then the helper path, the
  /// mode word and the token, the token last; a window with an id and no tty.
  @Test func opensGhosttyWithTheTokenLast() throws {
    let ghostty = try Self.builtIn("ghostty")
    let harness = Self.harness(version: "1.3.1")
    harness.runner.queued[.open] = [.success(Self.openReply("W-1", ""))]
    let window = try harness.windows.open(ghostty, helperPath: Self.helper, token: Self.token)
    #expect(window == PlainTerminalWindow(openedBy: ghostty, windowID: "W-1", tty: nil))
    let call = try #require(harness.runner.calls.first)
    #expect(harness.runner.calls.count == 1)
    #expect(call.script == "ghostty.applescript" && call.handler == .open)
    #expect(call.arguments == ["", Self.helper, "attach-plain", Self.token.rawValue])
    #expect(call.arguments.last == Self.token.rawValue)
    #expect(harness.runner.compiled == ["ghostty.applescript"])
  } // End of func opensGhosttyWithTheTokenLast()

  /// An `exec` definition: its program inside the app LaunchServices found (a path with a
  /// space is fine for an argv), every placeholder one whole argument, the layer's
  /// environment; no script compiled, no handler called, no permission read; a window with
  /// neither id nor tty, so nothing recorded.
  @Test func opensAnExecDefinitionBySpawning() throws {
    let exec = try Self.execDefinition()
    let harness = Self.harness(version: "20250101", running: false)
    let window = try harness.windows.open(exec, helperPath: Self.helper, token: Self.token)
    #expect(window == PlainTerminalWindow(openedBy: exec, windowID: nil, tty: nil))
    let request = try #require(harness.spawner.requests.first)
    #expect(harness.spawner.requests.count == 1)
    #expect(
      request.executable.path(percentEncoded: false)
        == "/Applications/Sample Terminal.app/Contents/MacOS/sample-terminal")
    #expect(
      request.arguments == [
        "start", "--always-new-process", "--", Self.helper, "attach-plain", Self.token.rawValue,
      ])
    #expect(request.environment == Self.environment)
    #expect(harness.runner.compiled.isEmpty && harness.runner.calls.isEmpty)
    #expect(harness.inspector.permissionReads.isEmpty)
    #expect(harness.inspector.snapshotReads == ["com.example.exec-terminal"])
    #expect(harness.windows.recordedWindows.isEmpty)
  } // End of func opensAnExecDefinitionBySpawning()

  /// A script is compiled once per loaded definition for the layer's lifetime, across opens,
  /// focuses and closes; another definition, a definition reloaded with another script, and a
  /// new layer each compile their own.
  @Test func compilesOncePerLoadedDefinition() throws {
    let terminal = try Self.builtIn("terminal")
    let ghostty = try Self.builtIn("ghostty")
    let harness = Self.harness(version: "2.15")
    harness.runner.fallback[.open] = .success(Self.openReply("7", "/dev/ttys007"))
    let first = try harness.windows.open(terminal, helperPath: Self.helper, token: Self.token)
    _ = try harness.windows.open(terminal, helperPath: Self.helper, token: LaunchToken())
    try harness.windows.focus(first, of: terminal)
    try harness.windows.close(first, of: terminal)
    #expect(harness.runner.compiled == ["terminal.applescript"])
    #expect(harness.runner.calls.map(\.handler) == [.open, .open, .focus, .close])
    harness.inspector.setSnapshot(TerminalAppSnapshot(url: Self.app, version: "1.3", running: true))
    _ = try harness.windows.open(ghostty, helperPath: Self.helper, token: Self.token)
    let script = try #require(terminal.script)
    let reloaded = LoadedTerminalDefinition(
      definition: terminal.definition, source: .userOverride, fileName: terminal.fileName,
      script: TerminalScript(name: script.name, source: script.source + "\n-- changed\n"))
    harness.inspector.setSnapshot(
      TerminalAppSnapshot(url: Self.app, version: "2.15", running: true))
    _ = try harness.windows.open(reloaded, helperPath: Self.helper, token: Self.token)
    _ = try harness.windows.open(terminal, helperPath: Self.helper, token: Self.token)
    #expect(
      harness.runner.compiled
        == ["terminal.applescript", "ghostty.applescript", "terminal.applescript"])
    let other = PlainTerminalWindows(
      runner: harness.runner, inspector: harness.inspector, spawner: harness.spawner,
      activator: harness.activator)
    _ = try other.open(terminal, helperPath: Self.helper, token: Self.token)
    #expect(harness.runner.compiled.count == 4)
  } // End of func compilesOncePerLoadedDefinition()

  // MARK: - The facts gate

  /// Not installed, too old, an unknown version and a permission read as denied are typed
  /// failures before anything is compiled, called or started.
  @Test func refusesBeforeAnyEvent() throws {
    let ghostty = try Self.builtIn("ghostty")
    let cases: [(Harness, PlainTerminalWindowError)] = [
      (Self.harness(version: nil, installed: false), .appNotInstalled(appName: "Ghostty")),
      (
        Self.harness(version: "1.2.9"),
        .appTooOld(appName: "Ghostty", installed: "1.2.9", minimum: "1.3")
      ),
      (Self.harness(version: "1.3 (tip)"), .appVersionUnknown(appName: "Ghostty", minimum: "1.3")),
      (Self.harness(version: nil), .appVersionUnknown(appName: "Ghostty", minimum: "1.3")),
      (
        Self.harness(version: "1.3.1", status: AutomationPermission.deniedStatus),
        .permissionDenied(appName: "Ghostty")
      ),
    ]
    for (harness, expected) in cases {
      let error = Self.failure { () throws(PlainTerminalWindowError) in
        try harness.windows.open(ghostty, helperPath: Self.helper, token: Self.token)
      }
      #expect(error == expected)
      #expect(harness.runner.compiled.isEmpty && harness.runner.calls.isEmpty)
      #expect(harness.spawner.requests.isEmpty && harness.windows.recordedWindows.isEmpty)
    } // End of loop over the refused facts
  } // End of func refusesBeforeAnyEvent()

  /// A permission macOS would ask for (`notDetermined`), one it cannot tell because the app is
  /// not running (`targetNotRunning`), `granted` and any other status go ahead with the open.
  @Test func goesAheadWhenThePermissionIsNotRefused() throws {
    let terminal = try Self.builtIn("terminal")
    let statuses: [(Int32, Bool)] = [
      (AutomationPermission.notDeterminedStatus, true),
      (AutomationPermission.targetNotRunningStatus, false),
      (AutomationPermission.grantedStatus, true), (-1, true),
    ]
    for (status, running) in statuses {
      let harness = Self.harness(version: "2.15", running: running, status: status)
      let window = try harness.windows.open(terminal, helperPath: Self.helper, token: Self.token)
      #expect(window.definitionID == "terminal")
      #expect(harness.runner.calls.map(\.handler) == [.open])
    }
  } // End of func goesAheadWhenThePermissionIsNotRefused()

  /// An `exec` definition is checked for the app and its version, never for a permission; a
  /// refusal starts nothing.
  @Test func checksAnExecDefinitionsApp() throws {
    let exec = try Self.execDefinition()
    let cases: [(Harness, PlainTerminalWindowError)] = [
      (
        Self.harness(version: nil, installed: false),
        .appNotInstalled(appName: "Sample exec terminal")
      ),
      (
        Self.harness(version: "20240202"),
        .appTooOld(appName: "Sample exec terminal", installed: "20240202", minimum: "20240203")
      ),
      (
        Self.harness(version: "nightly"),
        .appVersionUnknown(appName: "Sample exec terminal", minimum: "20240203")
      ),
    ]
    for (harness, expected) in cases {
      let error = Self.failure { () throws(PlainTerminalWindowError) in
        try harness.windows.open(exec, helperPath: Self.helper, token: Self.token)
      }
      #expect(error == expected)
      #expect(harness.spawner.requests.isEmpty)
      #expect(harness.inspector.permissionReads.isEmpty)
    }
    let denied = Self.harness(version: "20240203", status: AutomationPermission.deniedStatus)
    _ = try denied.windows.open(exec, helperPath: Self.helper, token: Self.token)
    #expect(denied.spawner.requests.count == 1 && denied.inspector.permissionReads.isEmpty)
  } // End of func checksAnExecDefinitionsApp()

  // MARK: - Open failures

  /// A launch command the definition's form refuses (a space for `words`, a quote for
  /// `shellText`, a relative path for `exec`) is refused with its reason; nothing is compiled,
  /// called or started.
  @Test func refusesTheLaunchCommandBeforeAnything() throws {
    let cases: [(LoadedTerminalDefinition, String, TerminalLaunchCommandError)] = [
      (
        try Self.builtIn("ghostty"), "/Users/test/My Apps/muxfinder-launch",
        .helperPathUnsafeForWords
      ),
      (
        try Self.builtIn("terminal"), "/Users/test/it's/muxfinder-launch",
        .helperPathUnsafeForShellText
      ),
      (try Self.execDefinition(), "muxfinder-launch", .helperPathNotAbsolute),
    ]
    for (loaded, helper, reason) in cases {
      let harness = Self.harness(version: "20250101")
      let error = Self.failure { () throws(PlainTerminalWindowError) in
        try harness.windows.open(loaded, helperPath: helper, token: Self.token)
      }
      #expect(error == .launchCommandRefused(reason))
      #expect(error?.message == reason.message)
      #expect(harness.runner.compiled.isEmpty && harness.runner.calls.isEmpty)
      #expect(harness.spawner.requests.isEmpty)
    }
  } // End of func refusesTheLaunchCommandBeforeAnything()

  /// A compile failure (not kept: the next open compiles again), a handler failure with its
  /// OSA number, the permission refused at the event (-1743), a malformed reply, a missing
  /// script and a failed spawn are each typed; none records a window.
  @Test func typesEveryOpenFailure() throws {
    let terminal = try Self.builtIn("terminal")
    let harness = Self.harness(version: "2.15")
    /// The failure of one open of `loaded` in `harness`.
    func open(_ loaded: LoadedTerminalDefinition) -> PlainTerminalWindowError? {
      Self.failure { () throws(PlainTerminalWindowError) in
        try harness.windows.open(loaded, helperPath: Self.helper, token: Self.token)
      }
    }
    harness.runner.compileFailure = .compileFailed(errorNumber: -2741)
    #expect(
      open(terminal) == .scriptFailed(appName: "Terminal", .compileFailed(errorNumber: -2741)))
    #expect(harness.runner.calls.isEmpty)
    harness.runner.compileFailure = nil
    harness.runner.queued[.open] = [
      .failure(.callFailed(handler: .open, errorNumber: -1708)),
      .failure(.callFailed(handler: .open, errorNumber: -1743)),
      .failure(.callFailed(handler: .open, errorNumber: -1728)),
      .success(.text("4711")),
      .success(.list([.text("1"), .text("ttys004")])),
    ]
    #expect(
      open(terminal)
        == .scriptFailed(appName: "Terminal", .callFailed(handler: .open, errorNumber: -1708)))
    #expect(harness.runner.compiled == ["terminal.applescript", "terminal.applescript"])
    #expect(open(terminal) == .permissionDenied(appName: "Terminal"))
    #expect(
      open(terminal)
        == .scriptFailed(appName: "Terminal", .callFailed(handler: .open, errorNumber: -1728)))
    #expect(open(terminal) == .malformedReply(appName: "Terminal", handler: .open))
    #expect(open(terminal) == .malformedReply(appName: "Terminal", handler: .open))
    let scriptless = LoadedTerminalDefinition(
      definition: terminal.definition, source: .user, fileName: "terminal.json", script: nil)
    #expect(open(scriptless) == .scriptMissing(appName: "Terminal"))
    #expect(harness.windows.recordedWindows.isEmpty)

    let exec = try Self.execDefinition()
    let spawning = Self.harness(version: "20250101")
    spawning.spawner.setFailure(.spawnFailed(errno: ENOENT))
    let error = Self.failure { () throws(PlainTerminalWindowError) in
      try spawning.windows.open(exec, helperPath: Self.helper, token: Self.token)
    }
    #expect(error == .spawnFailed(appName: "Sample exec terminal", .spawnFailed(errno: ENOENT)))
    #expect(spawning.spawner.requests.count == 1)
  } // End of func typesEveryOpenFailure()

  // MARK: - Focus

  /// `tty` focus (Terminal): `muxfinder_focus` with an empty window id and the window's
  /// terminal device; a window without one is refused with nothing sent.
  @Test func focusesByTerminalDevice() throws {
    let terminal = try Self.builtIn("terminal")
    let harness = Self.harness(version: "2.15")
    harness.runner.queued[.open] = [
      .success(Self.openReply("4711", "/dev/ttys004")), .success(Self.openReply("4712", "")),
    ]
    let window = try harness.windows.open(terminal, helperPath: Self.helper, token: Self.token)
    let blind = try harness.windows.open(terminal, helperPath: Self.helper, token: Self.token)
    try harness.windows.focus(window, of: terminal)
    #expect(
      harness.runner.calls.last
        == .init(script: "terminal.applescript", handler: .focus, arguments: ["", "/dev/ttys004"]))
    let calls = harness.runner.calls.count
    #expect(
      Self.failure { () throws(PlainTerminalWindowError) in
        try harness.windows.focus(blind, of: terminal)
      } == .windowLacksFocusValue(appName: "Terminal", .tty))
    #expect(harness.runner.calls.count == calls)
    #expect(harness.activator.requests.isEmpty)
  } // End of func focusesByTerminalDevice()

  /// `windowID` focus (Ghostty): `muxfinder_focus` with the window's id and an empty tty; a
  /// window without an id is refused with nothing sent.
  @Test func focusesByWindowID() throws {
    let ghostty = try Self.builtIn("ghostty")
    let harness = Self.harness(version: "1.3.1")
    harness.runner.queued[.open] = [.success(Self.openReply("W-1", ""))]
    let window = try harness.windows.open(ghostty, helperPath: Self.helper, token: Self.token)
    try harness.windows.focus(window, of: ghostty)
    #expect(
      harness.runner.calls.last
        == .init(script: "ghostty.applescript", handler: .focus, arguments: ["W-1", ""]))
    let calls = harness.runner.calls.count
    let anonymous = PlainTerminalWindow(openedBy: ghostty, windowID: nil, tty: "/dev/ttys1")
    #expect(
      Self.failure { () throws(PlainTerminalWindowError) in
        try harness.windows.focus(anonymous, of: ghostty)
      } == .windowLacksFocusValue(appName: "Ghostty", .windowID))
    #expect(harness.runner.calls.count == calls)
  } // End of func focusesByWindowID()

  /// `app` focus: the activator, by bundle identifier, with no Apple event, no compile and no
  /// facts read; not running and a refusal are typed.
  @Test func focusesTheAppWithoutAnEvent() throws {
    let exec = try Self.execDefinition()
    let harness = Self.harness(version: "20250101")
    let window = try harness.windows.open(exec, helperPath: Self.helper, token: Self.token)
    let reads = harness.inspector.snapshotReads.count
    try harness.windows.focus(window, of: exec)
    #expect(harness.activator.requests == ["com.example.exec-terminal"])
    harness.activator.answer = .notRunning
    #expect(
      Self.failure { () throws(PlainTerminalWindowError) in
        try harness.windows.focus(window, of: exec)
      } == .appNotRunning(appName: "Sample exec terminal"))
    harness.activator.answer = .refused
    #expect(
      Self.failure { () throws(PlainTerminalWindowError) in
        try harness.windows.focus(window, of: exec)
      } == .activationFailed(appName: "Sample exec terminal"))
    #expect(harness.activator.requests.count == 3)
    #expect(harness.runner.compiled.isEmpty && harness.runner.calls.isEmpty)
    #expect(harness.inspector.snapshotReads.count == reads)
  } // End of func focusesTheAppWithoutAnEvent()

  /// A focus sends nothing to an app that is not running (an event would launch it) or whose
  /// permission reads denied, nor for another definition's window; a window the app no longer
  /// has (-1728) is `windowGone`.
  @Test func focusRefusals() throws {
    let ghostty = try Self.builtIn("ghostty")
    let terminal = try Self.builtIn("terminal")
    let harness = Self.harness(version: "1.3.1")
    harness.runner.queued[.open] = [.success(Self.openReply("W-1", ""))]
    let window = try harness.windows.open(ghostty, helperPath: Self.helper, token: Self.token)
    /// The failure of one focus of `window` with `loaded`.
    func focus(_ loaded: LoadedTerminalDefinition) -> PlainTerminalWindowError? {
      Self.failure { () throws(PlainTerminalWindowError) in
        try harness.windows.focus(window, of: loaded)
      }
    }
    #expect(focus(terminal) == .windowOfAnotherTerminal)
    harness.inspector.setSnapshot(
      TerminalAppSnapshot(url: Self.app, version: "1.3.1", running: false))
    harness.inspector.setStatus(AutomationPermission.targetNotRunningStatus)
    #expect(focus(ghostty) == .appNotRunning(appName: "Ghostty"))
    harness.inspector.setSnapshot(
      TerminalAppSnapshot(url: Self.app, version: "1.3.1", running: true))
    harness.inspector.setStatus(AutomationPermission.deniedStatus)
    #expect(focus(ghostty) == .permissionDenied(appName: "Ghostty"))
    #expect(harness.runner.calls.map(\.handler) == [.open])
    harness.inspector.setStatus(AutomationPermission.grantedStatus)
    harness.runner.queued[.focus] = [
      .failure(.callFailed(handler: .focus, errorNumber: -1728)),
      .failure(.callFailed(handler: .focus, errorNumber: 1001)),
      .success(.text("x")),
    ]
    #expect(focus(ghostty) == .windowGone(appName: "Ghostty"))
    #expect(
      focus(ghostty)
        == .scriptFailed(appName: "Ghostty", .callFailed(handler: .focus, errorNumber: 1001)))
    #expect(focus(ghostty) == .malformedReply(appName: "Ghostty", handler: .focus))
  } // End of func focusRefusals()

  // MARK: - Close

  /// Close goes only to a window id this layer's own open recorded, through `muxfinder_close`
  /// with that id, once: afterwards, and for a window never opened here, another definition's
  /// window or a window without an id, it is refused with nothing sent.
  @Test func closesOnlyRecordedWindows() throws {
    let ghostty = try Self.builtIn("ghostty")
    let terminal = try Self.builtIn("terminal")
    let harness = Self.harness(version: "2.15")
    harness.runner.queued[.open] = [
      .success(Self.openReply("4711", "/dev/ttys004")), .success(Self.openReply("", "/dev/ttys5")),
    ]
    let window = try harness.windows.open(terminal, helperPath: Self.helper, token: Self.token)
    let unnamed = try harness.windows.open(terminal, helperPath: Self.helper, token: Self.token)
    try harness.windows.close(window, of: terminal)
    #expect(
      harness.runner.calls.last
        == .init(script: "terminal.applescript", handler: .close, arguments: ["4711"]))
    let calls = harness.runner.calls.count
    /// The failure of one close of `window` with `loaded`.
    func close(
      _ window: PlainTerminalWindow,
      _ loaded: LoadedTerminalDefinition
    ) -> PlainTerminalWindowError? {
      Self.failure { () throws(PlainTerminalWindowError) in
        try harness.windows.close(window, of: loaded)
      }
    }
    #expect(close(window, terminal) == .notOpenedHere)
    #expect(
      close(PlainTerminalWindow(openedBy: terminal, windowID: "99", tty: nil), terminal)
        == .notOpenedHere)
    #expect(close(window, ghostty) == .windowOfAnotherTerminal)
    #expect(close(unnamed, terminal) == .windowHasNoID(appName: "Terminal"))
    let exec = try Self.execDefinition()
    let execHarness = Self.harness(version: "20250101")
    let execWindow = try execHarness.windows.open(exec, helperPath: Self.helper, token: Self.token)
    #expect(
      Self.failure { () throws(PlainTerminalWindowError) in
        try execHarness.windows.close(execWindow, of: exec)
      } == .windowHasNoID(appName: "Sample exec terminal"))
    #expect(harness.runner.calls.count == calls)
    #expect(execHarness.runner.calls.isEmpty && execHarness.activator.requests.isEmpty)
  } // End of func closesOnlyRecordedWindows()

  /// The script's refusals: a busy window (1001) is `windowBusy` and stays recorded, so a later
  /// close goes out; a missing one (-1728) is `windowGone` and forgotten; any other failure
  /// keeps the record; an app that is not running gets nothing and the record is forgotten.
  @Test func closeMapsBusyAndMissingWindows() throws {
    let ghostty = try Self.builtIn("ghostty")
    let harness = Self.harness(version: "1.3.1")
    harness.runner.fallback[.open] = .success(Self.openReply("W-1", ""))
    let window = try harness.windows.open(ghostty, helperPath: Self.helper, token: Self.token)
    /// The failure of one close of `window`.
    func close() -> PlainTerminalWindowError? {
      Self.failure { () throws(PlainTerminalWindowError) in
        try harness.windows.close(window, of: ghostty)
      }
    }
    harness.runner.queued[.close] = [
      .failure(.callFailed(handler: .close, errorNumber: 1001)),
      .failure(.callFailed(handler: .close, errorNumber: -1708)),
      .success(.list([])),
      .failure(.callFailed(handler: .close, errorNumber: -1728)),
    ]
    #expect(close() == .windowBusy(appName: "Ghostty"))
    #expect(
      close() == .scriptFailed(appName: "Ghostty", .callFailed(handler: .close, errorNumber: -1708))
    )
    #expect(close() == .malformedReply(appName: "Ghostty", handler: .close))
    #expect(close() == .windowGone(appName: "Ghostty"))
    #expect(close() == .notOpenedHere)
    #expect(harness.runner.calls.filter { $0.handler == .close }.count == 4)

    _ = try harness.windows.open(ghostty, helperPath: Self.helper, token: Self.token)
    harness.inspector.setSnapshot(
      TerminalAppSnapshot(url: Self.app, version: "1.3.1", running: false))
    harness.inspector.setStatus(AutomationPermission.targetNotRunningStatus)
    #expect(close() == .appNotRunning(appName: "Ghostty"))
    harness.inspector.setSnapshot(
      TerminalAppSnapshot(url: Self.app, version: "1.3.1", running: true))
    #expect(close() == .notOpenedHere)
    #expect(harness.runner.calls.filter { $0.handler == .close }.count == 4)
    _ = try harness.windows.open(ghostty, helperPath: Self.helper, token: Self.token)
    harness.inspector.setStatus(AutomationPermission.deniedStatus)
    #expect(close() == .permissionDenied(appName: "Ghostty"))
    harness.inspector.setStatus(AutomationPermission.grantedStatus)
    #expect(close() == nil)
    #expect(harness.runner.calls.filter { $0.handler == .close }.count == 5)
  } // End of func closeMapsBusyAndMissingWindows()

  /// The layer keeps the newest `rememberedWindows` window ids: an older one is no longer
  /// closed (it stays open), and an id opened again counts as new.
  @Test func remembersTheNewestWindows() throws {
    let ghostty = try Self.builtIn("ghostty")
    let harness = Self.harness(version: "1.3.1")
    let count = PlainTerminalWindows.rememberedWindows + 1
    harness.runner.queued[.open] =
      (1...count).map { .success(Self.openReply("W-\($0)", "")) } + [
        .success(Self.openReply("W-2", ""))
      ]
    var windows: [PlainTerminalWindow] = []
    for _ in 0...count {
      windows.append(try harness.windows.open(ghostty, helperPath: Self.helper, token: Self.token))
    }
    #expect(harness.windows.recordedWindows.count == PlainTerminalWindows.rememberedWindows)
    #expect(harness.windows.recordedWindows.last?.windowID == "W-2")
    #expect(
      Self.failure { () throws(PlainTerminalWindowError) in
        try harness.windows.close(windows[0], of: ghostty)
      } == .notOpenedHere)
    try harness.windows.close(windows[1], of: ghostty)
    try harness.windows.close(windows[count - 1], of: ghostty)
    #expect(
      harness.runner.calls.filter { $0.handler == .close }.map(\.arguments) == [
        ["W-2"], ["W-\(count)"],
      ])
  } // End of func remembersTheNewestWindows()

  // MARK: - Review fixes: the opener and forgetting

  /// `loaded` with another id, display name, bundle identifier, focus kind or script (each kept
  /// when not given), as a user file would load it.
  static func variant(
    of loaded: LoadedTerminalDefinition,
    id: String? = nil,
    displayName: String? = nil,
    bundleIdentifier: String? = nil,
    focus: TerminalFocusKind? = nil,
    script: TerminalScript? = nil
  ) -> LoadedTerminalDefinition {
    let base = loaded.definition
    let definition = TerminalDefinition(
      id: id ?? base.id, displayName: displayName ?? base.displayName,
      bundleIdentifier: bundleIdentifier ?? base.bundleIdentifier,
      minimumVersion: base.minimumVersion, notes: base.notes, open: base.open,
      focus: focus ?? base.focus, keepsMinimumLifetime: base.keepsMinimumLifetime)
    return LoadedTerminalDefinition(
      definition: definition, source: .userOverride, fileName: "\(definition.id).json",
      script: script ?? loaded.script)
  } // End of static func variant(of:id:displayName:bundleIdentifier:focus:script:)

  /// The calls to `muxfinder_close` so far, by their arguments.
  static func closeCalls(_ harness: Harness) -> [[String]] {
    harness.runner.calls.filter { $0.handler == .close }.map(\.arguments)
  }

  /// A window is bound to the loaded definition that opened it (review finding 1): a focus or
  /// close through another loaded definition with the same id (an override for another app
  /// with its own script, or the definition loaded again with another script) is
  /// `definitionChanged`, naming the window's app, with nothing read, compiled or sent; a window
  /// value naming such a definition with the recorded id is `notOpenedHere` (the record is bound
  /// too); the same files loaded again give an equal definition, which still focuses and closes.
  /// An `app` focus is bound the same way: another app's bundle identifier never reaches the
  /// activator for this window.
  @Test func bindsAWindowToTheDefinitionThatOpenedIt() throws {
    let terminal = try Self.builtIn("terminal")
    let script = try #require(terminal.script)
    let otherApp = Self.variant(
      of: terminal, displayName: "Other terminal",
      bundleIdentifier: "com.example.other-terminal",
      script: TerminalScript(name: script.name, source: "-- another app's script\n"))
    let otherScript = Self.variant(
      of: terminal, script: TerminalScript(name: script.name, source: script.source + "\n--\n"))
    let harness = Self.harness(version: "2.15")
    harness.runner.queued[.open] = [.success(Self.openReply("4711", "/dev/ttys004"))]
    let window = try harness.windows.open(terminal, helperPath: Self.helper, token: Self.token)
    #expect(window.openedBy == terminal && window.definitionID == "terminal")
    let reads = harness.inspector.snapshotReads.count
    for replacement in [otherApp, otherScript] {
      #expect(
        Self.failure { () throws(PlainTerminalWindowError) in
          try harness.windows.focus(window, of: replacement)
        } == .definitionChanged(appName: "Terminal"))
      #expect(
        Self.failure { () throws(PlainTerminalWindowError) in
          try harness.windows.close(window, of: replacement)
        } == .definitionChanged(appName: "Terminal"))
      let forged = PlainTerminalWindow(
        openedBy: replacement, windowID: "4711", tty: "/dev/ttys004")
      #expect(
        Self.failure { () throws(PlainTerminalWindowError) in
          try harness.windows.close(forged, of: replacement)
        } == .notOpenedHere)
    } // End of loop over the replacement definitions
    #expect(harness.runner.compiled == ["terminal.applescript"])
    #expect(harness.runner.calls.map(\.handler) == [.open])
    #expect(harness.inspector.snapshotReads.count == reads)
    #expect(harness.windows.recordedWindows == [.init(openedBy: terminal, windowID: "4711")])
    let reloaded = try Self.builtIn("terminal")
    #expect(reloaded == terminal)
    try harness.windows.focus(window, of: reloaded)
    try harness.windows.close(window, of: reloaded)
    #expect(harness.runner.calls.map(\.handler) == [.open, .focus, .close])
    #expect(Self.closeCalls(harness) == [["4711"]])
    #expect(harness.runner.compiled == ["terminal.applescript"])

    let exec = try Self.execDefinition()
    let execHarness = Self.harness(version: "20250101")
    let execWindow = try execHarness.windows.open(exec, helperPath: Self.helper, token: Self.token)
    let movedExec = Self.variant(of: exec, bundleIdentifier: "com.example.another-app")
    #expect(
      Self.failure { () throws(PlainTerminalWindowError) in
        try execHarness.windows.focus(execWindow, of: movedExec)
      } == .definitionChanged(appName: "Sample exec terminal"))
    #expect(execHarness.activator.requests.isEmpty)
    try execHarness.windows.focus(execWindow, of: exec)
    #expect(execHarness.activator.requests == ["com.example.exec-terminal"])
  } // End of func bindsAWindowToTheDefinitionThatOpenedIt()

  /// A focus that finds the window missing (-1728) forgets its record (review finding 2), by
  /// terminal device (Terminal) and by window id (Ghostty): a later close of that window is
  /// `notOpenedHere` with nothing sent, so its stale id never reaches `muxfinder_close`. The
  /// other window keeps its record and still closes.
  @Test func focusFindingTheWindowGoneRevokesItsClose() throws {
    for id in ["terminal", "ghostty"] {
      let loaded = try Self.builtIn(id)
      let app = loaded.definition.displayName
      let harness = Self.harness(version: "2.15")
      harness.runner.queued[.open] = [
        .success(Self.openReply("7", "/dev/ttys007")),
        .success(Self.openReply("8", "/dev/ttys008")),
      ]
      let gone = try harness.windows.open(loaded, helperPath: Self.helper, token: Self.token)
      let kept = try harness.windows.open(loaded, helperPath: Self.helper, token: Self.token)
      harness.runner.queued[.focus] = [.failure(.callFailed(handler: .focus, errorNumber: -1728))]
      #expect(
        Self.failure { () throws(PlainTerminalWindowError) in
          try harness.windows.focus(gone, of: loaded)
        } == .windowGone(appName: app))
      #expect(harness.windows.recordedWindows == [.init(openedBy: loaded, windowID: "8")])
      #expect(
        Self.failure { () throws(PlainTerminalWindowError) in
          try harness.windows.close(gone, of: loaded)
        } == .notOpenedHere)
      #expect(Self.closeCalls(harness).isEmpty)
      try harness.windows.close(kept, of: loaded)
      #expect(Self.closeCalls(harness) == [["8"]])
    } // End of loop over Terminal and Ghostty
  } // End of func focusFindingTheWindowGoneRevokesItsClose()

  /// An app seen not running has every window recorded for it forgotten (review finding 2:
  /// window ids are not stable across a restart of the app), whichever loaded definition with
  /// its bundle identifier opened them (compared without regard to case), and only those: seen
  /// by a focus's facts, by an `app` focus's activator, and by an open's facts (before its new
  /// window is recorded). A later close of such a window is `notOpenedHere` with nothing sent.
  @Test func anAppSeenNotRunningRevokesItsWindows() throws {
    let terminal = try Self.builtIn("terminal")
    let ghostty = try Self.builtIn("ghostty")
    let appFocus = Self.variant(
      of: terminal, id: "terminal-app", bundleIdentifier: "com.apple.terminal", focus: .app)
    let harness = Self.harness(version: "2.15")
    harness.runner.queued[.open] = ["1", "2", "G", "3", "4", "5"].map {
      .success(Self.openReply($0, "/dev/ttys0\($0)"))
    }
    /// Opens a window through `loaded`.
    func open(_ loaded: LoadedTerminalDefinition) throws -> PlainTerminalWindow {
      try harness.windows.open(loaded, helperPath: Self.helper, token: Self.token)
    }
    /// The failure of one close of `window` with `loaded`.
    func close(
      _ window: PlainTerminalWindow,
      _ loaded: LoadedTerminalDefinition
    ) -> PlainTerminalWindowError? {
      Self.failure { () throws(PlainTerminalWindowError) in
        try harness.windows.close(window, of: loaded)
      }
    }
    /// Sets whether the fake inspector finds the app running.
    func setRunning(_ running: Bool) {
      harness.inspector.setSnapshot(
        TerminalAppSnapshot(url: Self.app, version: "2.15", running: running))
    }
    let first = try open(terminal)
    let second = try open(appFocus)
    let ghosttyWindow = try open(ghostty)
    setRunning(false)
    #expect(
      Self.failure { () throws(PlainTerminalWindowError) in
        try harness.windows.focus(first, of: terminal)
      } == .appNotRunning(appName: "Terminal"))
    #expect(harness.windows.recordedWindows == [.init(openedBy: ghostty, windowID: "G")])
    setRunning(true)
    #expect(close(first, terminal) == .notOpenedHere)
    #expect(close(second, appFocus) == .notOpenedHere)
    #expect(Self.closeCalls(harness).isEmpty)
    #expect(close(ghosttyWindow, ghostty) == nil)

    let third = try open(appFocus)
    harness.activator.answer = .notRunning
    #expect(
      Self.failure { () throws(PlainTerminalWindowError) in
        try harness.windows.focus(third, of: appFocus)
      } == .appNotRunning(appName: "Terminal"))
    #expect(harness.activator.requests == ["com.apple.terminal"])
    #expect(close(third, appFocus) == .notOpenedHere)

    let fourth = try open(terminal)
    setRunning(false)
    let fifth = try open(terminal)
    #expect(harness.windows.recordedWindows == [.init(openedBy: terminal, windowID: "5")])
    setRunning(true)
    #expect(close(fourth, terminal) == .notOpenedHere)
    #expect(close(fifth, terminal) == nil)
    #expect(Self.closeCalls(harness) == [["G"], ["5"]])
  } // End of func anAppSeenNotRunningRevokesItsWindows()
} // End of struct PlainTerminalWindowsTests
