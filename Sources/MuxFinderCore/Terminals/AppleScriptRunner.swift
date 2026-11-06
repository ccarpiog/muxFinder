import Carbon.OpenScripting
import Foundation

/// The fixed handlers a terminal definition's script defines (PLAN.md D38, Phase I-12b1).
/// Their names are never configurable: a definition names only its script file.
///
/// - `muxfinder_open(commandText, helperPath, modeWord, token)` opens a new window running the
///   launch command (the form the definition does not use is empty text) and returns a list of
///   two texts, `{windowID, tty}`, either empty when unknown.
/// - `muxfinder_focus(windowID, tty)` brings that window forward and returns nothing.
/// - `muxfinder_close(windowID)` closes that window, only by that id, and returns nothing.
public enum TerminalScriptHandler: String, Sendable, Hashable, CaseIterable {
  /// `muxfinder_open`.
  case open = "muxfinder_open"
  /// `muxfinder_focus`.
  case focus = "muxfinder_focus"
  /// `muxfinder_close`.
  case close = "muxfinder_close"

  /// How many text arguments the handler takes.
  public var argumentCount: Int {
    switch self {
    case .open: return 4
    case .focus: return 2
    case .close: return 1
    }
  }
} // End of enum TerminalScriptHandler

/// A handler's reply, read from its Apple event descriptor.
public indirect enum AppleScriptValue: Sendable, Hashable {
  /// No value (`typeNull`): what a bare `return` gives.
  case nothing
  /// Text.
  case text(String)
  /// A list.
  case list([AppleScriptValue])
  /// Anything else, by its descriptor type's four-character code (such as `long`).
  case other(type: String)
}

/// Why compiling a script or calling one of its handlers failed.
public enum AppleScriptRunnerError: Error, Sendable, Hashable {
  /// The script did not compile; the OSA error number.
  case compileFailed(errorNumber: Int)
  /// The handler raised an error, or the call could not be made; the OSA error number (for
  /// example -1708 for a handler the script lacks, -1728 for an object that is not there,
  /// -1743 when the Automation permission is denied).
  case callFailed(handler: TerminalScriptHandler, errorNumber: Int)
  /// The caller passed a number of arguments other than the handler's.
  case wrongArgumentCount(handler: TerminalScriptHandler)

  /// The OSA error number, when there is one.
  public var errorNumber: Int? {
    switch self {
    case .compileFailed(let number), .callFailed(_, let number): return number
    case .wrongArgumentCount: return nil
    }
  }
} // End of enum AppleScriptRunnerError

/// Compiles terminal scripts and calls their handlers (PLAN.md D38). A seam: the app uses
/// `NSAppleScriptRunner`, tests `FakeAppleScriptRunner`. Script source is compiled exactly as
/// the loader read it; values only ever travel as handler arguments.
@MainActor
public protocol AppleScriptRunning {
  /// Compiles `script` once; the result is called as often as needed.
  func compile(_ script: TerminalScript) throws(AppleScriptRunnerError) -> any CompiledAppleScript
}

/// A compiled terminal script.
@MainActor
public protocol CompiledAppleScript: AnyObject {
  /// The script file's name.
  var name: String { get }
  /// Calls `handler` with `arguments` (texts, exactly `handler.argumentCount`) in one Apple
  /// event and returns its reply.
  func call(
    _ handler: TerminalScriptHandler,
    arguments: [String]
  ) throws(AppleScriptRunnerError) -> AppleScriptValue
}

/// The real runner, over `NSAppleScript` on the main actor. A call is one
/// `kASAppleScriptSuite`/`kASSubroutineEvent` event to the compiled script, with the handler's
/// name in `keyASSubroutineName` and the arguments as a list of texts in the direct object;
/// the script's source is never built from values.
///
/// Compiling a script that has a `tell application` block reads that app's dictionary, which
/// may launch it: so nothing in a test, the probe or the build compiles a built-in script
/// (PLAN.md *Unattended-run rules* 8).
@MainActor
public struct NSAppleScriptRunner: AppleScriptRunning {
  /// Lists nested deeper than this are read as `other(type: "list")`.
  static let maximumListDepth = 4
  /// The number used when an error carries none (`errOSAGeneralError`).
  static let unknownErrorNumber = -2700

  /// A runner.
  public init() {}

  /// Compiles `script.source` with `NSAppleScript`.
  public func compile(
    _ script: TerminalScript
  ) throws(AppleScriptRunnerError) -> any CompiledAppleScript {
    guard let compiled = NSAppleScript(source: script.source) else {
      throw .compileFailed(errorNumber: Self.unknownErrorNumber)
    }
    var errorInfo: NSDictionary?
    guard compiled.compileAndReturnError(&errorInfo) else {
      throw .compileFailed(errorNumber: Self.errorNumber(in: errorInfo))
    }
    return CompiledNSAppleScript(name: script.name, script: compiled)
  } // End of func compile(_:)

  /// The error number in an `NSAppleScript` error dictionary (a number or its text), or
  /// `unknownErrorNumber`.
  static func errorNumber(in info: NSDictionary?) -> Int {
    switch info?[NSAppleScript.errorNumber] {
    case let number as NSNumber: return number.intValue
    case let text as String: return Int(text) ?? unknownErrorNumber
    default: return unknownErrorNumber
    }
  }

  /// The handler call event: `kASSubroutineEvent` to this process, `handler`'s name, the
  /// arguments as a list of texts.
  static func event(
    _ handler: TerminalScriptHandler,
    arguments: [String]
  ) -> NSAppleEventDescriptor {
    let event = NSAppleEventDescriptor(
      eventClass: AEEventClass(kASAppleScriptSuite),
      eventID: AEEventID(kASSubroutineEvent),
      targetDescriptor: .currentProcess(),
      returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID)
    )
    event.setDescriptor(
      NSAppleEventDescriptor(string: handler.rawValue), forKeyword: AEKeyword(keyASSubroutineName))
    let list = NSAppleEventDescriptor.list()
    for (index, argument) in arguments.enumerated() {
      list.insert(NSAppleEventDescriptor(string: argument), at: index + 1)
    }
    event.setParam(list, forKeyword: keyDirectObject)
    return event
  } // End of static func event(_:arguments:)

  /// Reads `descriptor` as a typed value: null, text (Unicode, UTF-8 or plain), a list (at
  /// most `maximumListDepth` deep), or another type by its code.
  static func value(of descriptor: NSAppleEventDescriptor, depth: Int = 0) -> AppleScriptValue {
    switch descriptor.descriptorType {
    case DescType(typeNull):
      return .nothing
    case DescType(typeUnicodeText), DescType(typeUTF8Text), DescType(typeChar):
      return descriptor.stringValue.map(AppleScriptValue.text) ?? .other(type: "text")
    case DescType(typeAEList) where depth < maximumListDepth:
      let count = descriptor.numberOfItems
      guard count > 0 else { return .list([]) }
      return .list(
        (1...count).map { index in
          descriptor.atIndex(index).map { value(of: $0, depth: depth + 1) } ?? .nothing
        })
    default:
      return .other(type: fourCharacterCode(descriptor.descriptorType))
    }
  } // End of static func value(of:depth:)

  /// `code` as its four characters (`????` for bytes that are not printable ASCII).
  static func fourCharacterCode(_ code: DescType) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
    guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return "????" }
    return String(decoding: bytes, as: UTF8.self)
  }
} // End of struct NSAppleScriptRunner

/// A script compiled by `NSAppleScriptRunner`.
@MainActor
final class CompiledNSAppleScript: CompiledAppleScript {
  /// The script file's name.
  let name: String
  /// The compiled script.
  let script: NSAppleScript

  /// Wraps `script`, compiled from the file `name`.
  init(name: String, script: NSAppleScript) {
    self.name = name
    self.script = script
  }

  /// Calls `handler` in one Apple event and reads its reply.
  func call(
    _ handler: TerminalScriptHandler,
    arguments: [String]
  ) throws(AppleScriptRunnerError) -> AppleScriptValue {
    guard arguments.count == handler.argumentCount else {
      throw .wrongArgumentCount(handler: handler)
    }
    var errorInfo: NSDictionary?
    let reply = script.executeAppleEvent(
      NSAppleScriptRunner.event(handler, arguments: arguments), error: &errorInfo)
    if let errorInfo {
      throw .callFailed(
        handler: handler, errorNumber: NSAppleScriptRunner.errorNumber(in: errorInfo))
    }
    return NSAppleScriptRunner.value(of: reply)
  } // End of func call(_:arguments:)
} // End of class CompiledNSAppleScript
