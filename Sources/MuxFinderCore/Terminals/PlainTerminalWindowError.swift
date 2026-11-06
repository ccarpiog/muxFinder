import Darwin
import Foundation

/// Why the plain window layer (`PlainTerminalWindows`, PLAN.md D38, Phase I-12b3) could not
/// open, focus or close a terminal app's window. Every case is final for that request: nothing
/// is retried (D13). `appName` is the definition's display name; `message` is a plain English
/// sentence (sentence case, no paths, commands or terminal contents) for the UI.
public enum PlainTerminalWindowError: Error, Sendable, Hashable, LocalizedError {
  /// LaunchServices finds no app with the definition's bundle identifier. Nothing was sent.
  case appNotInstalled(appName: String)
  /// The installed app's version is below the definition's minimum. Nothing was sent.
  case appTooOld(appName: String, installed: String, minimum: String)
  /// The installed app's version is missing or does not read as a dotted decimal version, so
  /// it cannot be checked against the minimum (never a pass). Nothing was sent.
  case appVersionUnknown(appName: String, minimum: String)
  /// The Automation permission for the app reads as denied, or the app's answer said so
  /// (-1743). Nothing more was sent.
  case permissionDenied(appName: String)
  /// The app is not running: a focus or close never starts it (its windows are gone with it).
  /// Nothing was sent.
  case appNotRunning(appName: String)
  /// macOS did not bring the running app forward (a definition's `app` focus).
  case activationFailed(appName: String)
  /// The launch command cannot be built from the helper path, mode word and token in the
  /// definition's form. Nothing was compiled, sent or started.
  case launchCommandRefused(TerminalLaunchCommandError)
  /// The definition's script did not compile, or one of its handlers raised an error (or the
  /// call could not be made), with the OSA error number when there is one.
  case scriptFailed(appName: String, AppleScriptRunnerError)
  /// The definition opens with AppleScript but carries no script.
  case scriptMissing(appName: String)
  /// A handler answered something its contract does not allow.
  case malformedReply(appName: String, handler: TerminalScriptHandler)
  /// An `exec` definition's program could not be started.
  case spawnFailed(appName: String, ProcessRunnerError)
  /// The window belongs to another definition than the one given. Nothing was sent.
  case windowOfAnotherTerminal
  /// The window was opened through another loaded definition with the same id: a user override
  /// of a built-in, or the definition loaded again with other contents (another bundle
  /// identifier or script). Its id and terminal device belong to that definition's app and
  /// script, so nothing was sent. `appName` is the window's app (the opening definition's).
  case definitionChanged(appName: String)
  /// Close only: the window id is not one this layer's own open recorded for the given loaded
  /// definition, or its record was forgotten since (the window found missing, its app seen not
  /// running, or older than the newest 64). Nothing was sent.
  case notOpenedHere
  /// Focus only: the window lacks the value the definition's focus kind needs (its terminal
  /// device for `tty`, its id for `windowID`). Nothing was sent.
  case windowLacksFocusValue(appName: String, TerminalFocusKind)
  /// Close only: the app gave the window no id, so it cannot be closed by id. Nothing was sent.
  case windowHasNoID(appName: String)
  /// Close only: the window still runs a process, so the script left it open (1001).
  case windowBusy(appName: String)
  /// The window is not there any more (-1728).
  case windowGone(appName: String)
  /// An unattended run (`PlainRunPolicy.unattended`, *Unattended-run rules* 8) found, right
  /// before a side effect, that it may not go ahead: the app not installed, too old, not
  /// running or its permission not reading granted. Nothing was sent or launched.
  case unattendedRunRefused(appName: String, PlainRunGate.Refusal)

  /// A short machine-readable name, such as `appTooOld` or `windowBusy`.
  public var kind: String {
    switch self {
    case .appNotInstalled: return "appNotInstalled"
    case .appTooOld: return "appTooOld"
    case .appVersionUnknown: return "appVersionUnknown"
    case .permissionDenied: return "permissionDenied"
    case .appNotRunning: return "appNotRunning"
    case .activationFailed: return "activationFailed"
    case .launchCommandRefused: return "launchCommandRefused"
    case .scriptFailed: return "scriptFailed"
    case .scriptMissing: return "scriptMissing"
    case .malformedReply: return "malformedReply"
    case .spawnFailed: return "spawnFailed"
    case .windowOfAnotherTerminal: return "windowOfAnotherTerminal"
    case .definitionChanged: return "definitionChanged"
    case .notOpenedHere: return "notOpenedHere"
    case .windowLacksFocusValue: return "windowLacksFocusValue"
    case .windowHasNoID: return "windowHasNoID"
    case .windowBusy: return "windowBusy"
    case .windowGone: return "windowGone"
    case .unattendedRunRefused: return "unattendedRunRefused"
    }
  } // End of var kind

  /// The user-facing explanation.
  public var message: String {
    switch self {
    case .appNotInstalled(let app):
      return "muxFinder can't find \(app) on this Mac. Install it, or choose another terminal."
    case .appTooOld(let app, let installed, let minimum):
      return "\(app) \(installed) is too old for muxFinder. Update it to \(minimum) or later."
    case .appVersionUnknown(let app, let minimum):
      return "muxFinder can't tell which version of \(app) is installed, and it needs "
        + "\(minimum) or later. Update \(app) and try again."
    case .permissionDenied(let app):
      return "muxFinder isn't allowed to control \(app). Turn it on in System Settings › "
        + "Privacy & Security › Automation, then try again."
    case .appNotRunning(let app):
      return "\(app) isn't running, so the session's window is gone."
    case .activationFailed(let app):
      return "macOS didn't bring \(app) to the front. Switch to it to find the session's window."
    case .launchCommandRefused(let error):
      return error.message
    case .scriptFailed(let app, let error):
      return Self.scriptMessage(app: app, error: error)
    case .scriptMissing(let app):
      return "muxFinder's definition for \(app) has no script, so it can't open windows there."
    case .malformedReply(let app, _):
      return "\(app) answered muxFinder in a way it doesn't understand, so muxFinder stopped."
    case .spawnFailed(let app, let error):
      return "muxFinder couldn't start \(app)\(Self.reason(of: error))."
    case .windowOfAnotherTerminal:
      return "This window belongs to another terminal, so muxFinder left it alone."
    case .definitionChanged(let app):
      return "muxFinder's definition for \(app) changed after it opened this window, so "
        + "muxFinder left the window alone."
    case .notOpenedHere:
      return "muxFinder didn't open this window, so it won't close it."
    case .windowLacksFocusValue(let app, let kind):
      let what = kind == .tty ? "its terminal device" : "an id"
      return "\(app) didn't report \(what) for this window, so muxFinder can't bring it "
        + "forward. Switch to \(app) to find it."
    case .windowHasNoID(let app):
      return "\(app) didn't report an id for this window, so muxFinder can't close it. "
        + "Close it in \(app)."
    case .windowBusy(let app):
      return "The \(app) window is still running something, so muxFinder left it open."
    case .windowGone(let app):
      return "The \(app) window is already closed."
    case .unattendedRunRefused(let app, let refusal):
      return "muxFinder sent nothing to \(app) in an unattended run: \(refusal.message)."
    }
  } // End of var message

  /// `LocalizedError` conformance, so `localizedDescription` shows `message`.
  public var errorDescription: String? { message }

  /// The sentence for a script failure: a compile failure or a handler's, with the OSA number
  /// when there is one.
  static func scriptMessage(app: String, error: AppleScriptRunnerError) -> String {
    let number = error.errorNumber.map { " (error \($0))" } ?? ""
    switch error {
    case .compileFailed:
      return "muxFinder couldn't load its script for \(app)\(number)."
    case .callFailed(let handler, _), .wrongArgumentCount(let handler):
      let action: String
      switch handler {
      case .open: action = "open a window"
      case .focus: action = "bring the window forward"
      case .close: action = "close the window"
      }
      return "\(app) couldn't \(action)\(number)."
    }
  } // End of static func scriptMessage(app:error:)

  /// `error`'s system reason in parentheses, such as " (No such file or directory)", or empty.
  static func reason(of error: ProcessRunnerError) -> String {
    switch error {
    case .spawnFailed(let code), .systemCallFailed(_, let code):
      return " (\(String(cString: strerror(code))))"
    case .executableNotAbsolute, .argumentContainsNUL, .invalidEnvironmentVariable:
      return ""
    }
  }
} // End of enum PlainTerminalWindowError
