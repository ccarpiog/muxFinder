import Darwin
import Foundation

/// Why an iTerm2 API operation failed.
///
/// Every case's description is one English sentence without user data: no window titles,
/// commands, profile names or terminal contents. `requestFailed` keeps iTerm2's own error text
/// for callers, but its description leaves it out.
///
/// What a failed request (`listSessions`, `createTab`, `sendTmuxCommand`, …) tells about its
/// effect, since requests are never retried automatically (PLAN.md D13):
/// - **Not sent, no effect:** `notSent(reason)` (the request's frame was never written whole:
///   it was withdrawn before its write started, or the connection could not be opened), and
///   `notRunning`, `apiDisabled`, `automationDenied`, `cookieUnavailable`, `authRejected`,
///   which only ever happen while connecting.
/// - **Answered, definitive:** `requestFailed`, `createTabFailed`, `activateFailed`,
///   `tmuxRequestFailed`.
/// - **Sent, outcome unknown:** `timedOut`, `disconnected`, `protocolError` and
///   `connectionFailed` on their own (not wrapped in `notSent`): iTerm2 may have acted on the
///   request. `CancellationError` (the calling task was cancelled) is unknown too: a frame that
///   had not started writing is withdrawn and never sent, but the error does not tell which.
public enum ITerm2Error: Error, Sendable, Hashable, LocalizedError {
  /// iTerm2 is not running (checked by bundle id `com.googlecode.iterm2`). Nothing launched it.
  case notRunning
  /// iTerm2's API server is off: its socket is missing, or nobody accepts connections on it.
  case apiDisabled
  /// macOS refused the Apple event that requests the API cookie (AppleScript error -1743):
  /// muxFinder lacks the Automation permission for iTerm2.
  case automationDenied
  /// The AppleScript cookie request failed for another reason; the AppleScript error number.
  case cookieUnavailable(appleScriptError: Int)
  /// iTerm2 refused the WebSocket handshake for authentication (HTTP 401): the cookie was not
  /// accepted.
  case authRejected
  /// iTerm2 sent something this client does not accept. The detail names the rule that was
  /// broken; it never quotes received data.
  case protocolError(String)
  /// iTerm2 did not answer in time.
  case timedOut
  /// The connection ended (iTerm2 quit or closed it, or this side disconnected).
  case disconnected
  /// The API socket could not be reached for a reason other than the API being off.
  case connectionFailed(errno: Int32)
  /// iTerm2 answered a request with an error message (the `error` submessage); its text.
  case requestFailed(String)
  /// iTerm2 could not create the tab.
  case createTabFailed(ITerm2API.CreateTabResponse.Status)
  /// iTerm2 could not activate the window, tab or session.
  case activateFailed(ITerm2API.ActivateResponse.Status)
  /// iTerm2 rejected the tmux request.
  case tmuxRequestFailed(ITerm2API.TmuxResponse.Status)
  /// iTerm2 could not be launched; a plain detail without user data.
  case launchFailed(String)
  /// The request failed for `reason` (`timedOut`, `disconnected`, `protocolError` or
  /// `connectionFailed`) before its frame was written whole, so iTerm2 never acted on it: it
  /// was withdrawn while still queued (its deadline passed or its connection ended), the writer
  /// skipped it, its write failed, or no connection could be opened for it. Never nested.
  indirect case notSent(ITerm2Error)

  /// A stable machine-readable name for the case, used in JSON output.
  public var kind: String {
    switch self {
    case .notSent: return "notSent"
    case .notRunning: return "notRunning"
    case .apiDisabled: return "apiDisabled"
    case .automationDenied: return "automationDenied"
    case .cookieUnavailable: return "cookieUnavailable"
    case .authRejected: return "authRejected"
    case .protocolError: return "protocolError"
    case .timedOut: return "timedOut"
    case .disconnected: return "disconnected"
    case .connectionFailed: return "connectionFailed"
    case .requestFailed: return "requestFailed"
    case .createTabFailed: return "createTabFailed"
    case .activateFailed: return "activateFailed"
    case .tmuxRequestFailed: return "tmuxRequestFailed"
    case .launchFailed: return "launchFailed"
    }
  } // End of var kind

  /// The user-facing explanation, one sentence.
  public var errorDescription: String? {
    switch self {
    case .notRunning:
      return "iTerm2 is not running."
    case .apiDisabled:
      return "iTerm2's API server is off. Turn on \"Enable Python API\" in iTerm2's settings "
        + "(General > Magic)."
    case .automationDenied:
      return "muxFinder is not allowed to control iTerm2. Allow it in System Settings > "
        + "Privacy & Security > Automation."
    case .cookieUnavailable(let number):
      return "iTerm2 did not provide an API cookie (AppleScript error \(number))."
    case .authRejected:
      return "iTerm2 rejected muxFinder's API credentials."
    case .protocolError(let detail):
      return "iTerm2's API sent an unexpected reply: \(detail)."
    case .timedOut:
      return "iTerm2's API did not answer in time."
    case .disconnected:
      return "The connection to iTerm2's API was closed."
    case .connectionFailed(let number):
      return "Could not connect to iTerm2's API socket: \(String(cString: strerror(number)))."
    case .requestFailed:
      return "iTerm2 rejected the request."
    case .createTabFailed(let status):
      return "iTerm2 could not open the tab (\(Self.name(of: status)))."
    case .activateFailed(let status):
      return "iTerm2 could not bring the tab forward (\(Self.name(of: status)))."
    case .tmuxRequestFailed(let status):
      return "iTerm2 rejected the tmux request (\(Self.name(of: status)))."
    case .launchFailed(let detail):
      return "iTerm2 could not be launched: \(detail)."
    case .notSent(let reason):
      var cause = reason.errorDescription ?? reason.kind
      if cause.hasSuffix(".") { cause.removeLast() }
      return "\(cause); the request was not sent."
    }
  } // End of var errorDescription

  /// The status's name as iTerm2's protocol spells it.
  static func name(of status: ITerm2API.CreateTabResponse.Status) -> String {
    switch status {
    case .ok: return "OK"
    case .invalidProfileName: return "INVALID_PROFILE_NAME"
    case .invalidWindowID: return "INVALID_WINDOW_ID"
    case .invalidTabIndex: return "INVALID_TAB_INDEX"
    case .missingSubstitution: return "MISSING_SUBSTITUTION"
    case .unknown(let value): return "status \(value)"
    }
  }

  /// The status's name as iTerm2's protocol spells it.
  static func name(of status: ITerm2API.ActivateResponse.Status) -> String {
    switch status {
    case .ok: return "OK"
    case .badIdentifier: return "BAD_IDENTIFIER"
    case .invalidOption: return "INVALID_OPTION"
    case .unknown(let value): return "status \(value)"
    }
  }

  /// The status's name as iTerm2's protocol spells it.
  static func name(of status: ITerm2API.TmuxResponse.Status) -> String {
    switch status {
    case .ok: return "OK"
    case .invalidRequest: return "INVALID_REQUEST"
    case .invalidConnectionID: return "INVALID_CONNECTION_ID"
    case .invalidWindowID: return "INVALID_WINDOW_ID"
    case .unknown(let value): return "status \(value)"
    }
  }

  /// Maps a WebSocket-layer failure. A handshake refused with HTTP 401 is `authRejected` (the
  /// status iTerm2 uses for a bad cookie; iTerm2's Python module treats it the same way); 406
  /// means iTerm2 refused the client library version.
  init(_ error: WebSocketError) {
    switch error {
    case .timedOut:
      self = .timedOut
    case .endOfStream, .closed:
      self = .disconnected
    case .protocolViolation(let detail):
      self = .protocolError(detail)
    case .messageTooLarge(let limit):
      self = .protocolError("a message is longer than \(limit) bytes")
    case .handshakeRejected(401):
      self = .authRejected
    case .handshakeRejected(406):
      self = .protocolError("iTerm2 refused the client library version (HTTP 406)")
    case .handshakeRejected(let status):
      self = .protocolError("iTerm2 refused the WebSocket handshake (HTTP \(status))")
    case .transport(let failure):
      self = Self(failure)
    }
  } // End of init(_:) for WebSocketError

  /// Maps a byte-stream failure on an established connection.
  init(_ error: ByteStreamError) {
    switch error {
    case .timedOut: self = .timedOut
    case .shutDown, .closedByPeer: self = .disconnected
    case .systemCallFailed(_, let number): self = .connectionFailed(errno: number)
    }
  }
}
