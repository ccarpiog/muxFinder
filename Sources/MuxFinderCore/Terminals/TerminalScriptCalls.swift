import Foundation

/// What `muxfinder_open` returned: the new window's id and the new tab's terminal device, each
/// `nil` when the script did not know it.
public struct TerminalOpenReply: Sendable, Hashable {
  /// The window's id, as text (Terminal: an integer; Ghostty: its "Stable ID").
  public let windowID: String?
  /// The tab's terminal device, such as `/dev/ttys004`.
  public let tty: String?

  /// A reply with these values.
  public init(windowID: String?, tty: String?) {
    self.windowID = windowID
    self.tty = tty
  }
}

/// Why a call through a definition's handlers failed.
public enum TerminalScriptCallError: Error, Sendable, Hashable {
  /// The launch command could not be built from the helper path, mode word and token.
  case launchCommand(TerminalLaunchCommandError)
  /// The script failed to compile, or its handler raised an error (with the OSA number).
  case runner(AppleScriptRunnerError)
  /// The handler answered something the contract does not allow.
  case unexpectedReply(handler: TerminalScriptHandler)
  /// The definition opens with `exec`, so it has no handlers.
  case notAppleScript
}

/// Calls a definition's handlers with the contract's arguments and reads their replies
/// strictly (PLAN.md D38, Phase I-12b1): `muxfinder_open` must answer a list of exactly two
/// texts, each at most 256 bytes with no control character, the tty empty or a `/dev/` path;
/// `muxfinder_focus` and `muxfinder_close` must answer nothing (a bare `return`). Anything
/// else is `unexpectedReply`.
@MainActor
public struct TerminalScriptCalls {
  /// The error number a handler raises when the window it was given is not there
  /// (AppleScript's own `errAENoSuchObject`).
  public static let windowNotFoundErrorNumber = -1728
  /// The error number `muxfinder_close` raises when the window still runs a process, so it
  /// left the window open (closing it would ask the user first).
  public static let windowBusyErrorNumber = 1001
  /// The longest window id or tty accepted, in bytes.
  static let maximumReplyLength = 256
  /// The bytes a tty's name after `/dev/` may hold.
  static let ttyNameBytes: Set<UInt8> = Set(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-".utf8)

  /// The compiled script.
  public let script: any CompiledAppleScript
  /// The command form the definition gives its open.
  public let form: TerminalCommandForm

  /// Calls for the compiled `script` of an `appleScript` definition with `form`.
  public init(script: any CompiledAppleScript, form: TerminalCommandForm) {
    self.script = script
    self.form = form
  }

  /// Compiles `loaded`'s script with `runner` and returns its calls; `notAppleScript` for an
  /// `exec` definition.
  public static func compile(
    _ loaded: LoadedTerminalDefinition,
    with runner: any AppleScriptRunning
  ) throws(TerminalScriptCallError) -> TerminalScriptCalls {
    guard let form = loaded.definition.open.commandForm, let source = loaded.script else {
      throw .notAppleScript
    }
    do throws(AppleScriptRunnerError) {
      return TerminalScriptCalls(script: try runner.compile(source), form: form)
    } catch {
      throw .runner(error)
    }
  } // End of static func compile(_:with:)

  /// Opens a new window running `command` in the definition's form.
  public func open(_ command: TerminalLaunchCommand) throws(TerminalScriptCallError)
    -> TerminalOpenReply
  {
    let arguments: [String]
    do throws(TerminalLaunchCommandError) {
      arguments = try command.appleScriptArguments(form: form)
    } catch {
      throw .launchCommand(error)
    }
    let reply = try call(.open, arguments)
    guard let parsed = Self.openReply(from: reply) else {
      throw .unexpectedReply(handler: .open)
    }
    return parsed
  } // End of func open(_:)

  /// Brings forward the window with `windowID` or `tty` (empty text for an unknown one).
  public func focus(windowID: String?, tty: String?) throws(TerminalScriptCallError) {
    guard try call(.focus, [windowID ?? "", tty ?? ""]) == .nothing else {
      throw .unexpectedReply(handler: .focus)
    }
  }

  /// Closes the window with `windowID`, only that one.
  public func close(windowID: String) throws(TerminalScriptCallError) {
    guard try call(.close, [windowID]) == .nothing else {
      throw .unexpectedReply(handler: .close)
    }
  }

  /// Calls `handler`, mapping runner failures.
  func call(
    _ handler: TerminalScriptHandler,
    _ arguments: [String]
  ) throws(TerminalScriptCallError) -> AppleScriptValue {
    do throws(AppleScriptRunnerError) {
      return try script.call(handler, arguments: arguments)
    } catch {
      throw .runner(error)
    }
  }

  /// Reads `muxfinder_open`'s reply strictly: exactly two texts, each at most 256 bytes with
  /// no control character, the second empty or `/dev/` and a name of ASCII letters, digits,
  /// `.`, `_` and `-`. Empty texts are `nil`. Anything else is `nil` (not a reply).
  public static func openReply(from value: AppleScriptValue) -> TerminalOpenReply? {
    guard case .list(let items) = value, items.count == 2,
      case .text(let windowID) = items[0], case .text(let tty) = items[1]
    else { return nil }
    for text in [windowID, tty] {
      guard text.utf8.count <= maximumReplyLength,
        !text.unicodeScalars.contains(where: TerminalDefinition.isControl)
      else { return nil }
    }
    if !tty.isEmpty {
      let name = tty.utf8.dropFirst("/dev/".utf8.count)
      guard tty.hasPrefix("/dev/"), !name.isEmpty, name.allSatisfy(ttyNameBytes.contains) else {
        return nil
      }
    }
    return TerminalOpenReply(
      windowID: windowID.isEmpty ? nil : windowID, tty: tty.isEmpty ? nil : tty)
  } // End of static func openReply(from:)
} // End of struct TerminalScriptCalls

/// A runner for tests and previews: it compiles nothing, records every compile and call, and
/// answers each handler with queued replies first, then its fallback.
@MainActor
public final class FakeAppleScriptRunner: AppleScriptRunning {
  /// One recorded handler call.
  public struct Call: Sendable, Hashable {
    /// The script's file name.
    public let script: String
    /// The handler.
    public let handler: TerminalScriptHandler
    /// Its arguments.
    public let arguments: [String]
  }

  /// The names of the scripts compiled, in order.
  public private(set) var compiled: [String] = []
  /// Every handler call, in order.
  public private(set) var calls: [Call] = []
  /// When set, every compile fails with it.
  public var compileFailure: AppleScriptRunnerError?
  /// Replies used first, per handler, in order.
  public var queued: [TerminalScriptHandler: [Result<AppleScriptValue, AppleScriptRunnerError>]] =
    [:]
  /// The reply once a handler's queue is empty: for `open` two empty texts, else nothing.
  public var fallback: [TerminalScriptHandler: Result<AppleScriptValue, AppleScriptRunnerError>] =
    [
      .open: .success(.list([.text(""), .text("")])),
      .focus: .success(.nothing),
      .close: .success(.nothing),
    ]

  /// A runner with the default fallbacks.
  public init() {}

  /// Records the compile and returns a script whose calls come back here.
  public func compile(
    _ script: TerminalScript
  ) throws(AppleScriptRunnerError) -> any CompiledAppleScript {
    compiled.append(script.name)
    if let compileFailure { throw compileFailure }
    return FakeCompiledAppleScript(name: script.name, runner: self)
  }

  /// Records a call and returns its reply.
  func reply(
    script: String,
    handler: TerminalScriptHandler,
    arguments: [String]
  ) throws(AppleScriptRunnerError) -> AppleScriptValue {
    calls.append(Call(script: script, handler: handler, arguments: arguments))
    let result: Result<AppleScriptValue, AppleScriptRunnerError>
    if var queue = queued[handler], !queue.isEmpty {
      result = queue.removeFirst()
      queued[handler] = queue
    } else {
      result = fallback[handler] ?? .success(.nothing)
    }
    return try result.get()
  } // End of func reply(script:handler:arguments:)
} // End of class FakeAppleScriptRunner

/// A script "compiled" by `FakeAppleScriptRunner`.
@MainActor
final class FakeCompiledAppleScript: CompiledAppleScript {
  /// The script's file name.
  let name: String
  /// The runner that records the calls.
  let runner: FakeAppleScriptRunner

  /// A fake script named `name`.
  init(name: String, runner: FakeAppleScriptRunner) {
    self.name = name
    self.runner = runner
  }

  /// Checks the argument count as the real runner does, then asks the runner.
  func call(
    _ handler: TerminalScriptHandler,
    arguments: [String]
  ) throws(AppleScriptRunnerError) -> AppleScriptValue {
    guard arguments.count == handler.argumentCount else {
      throw .wrongArgumentCount(handler: handler)
    }
    return try runner.reply(script: name, handler: handler, arguments: arguments)
  }
} // End of class FakeCompiledAppleScript
