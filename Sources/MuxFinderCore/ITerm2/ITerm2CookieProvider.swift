import AppKit
import Foundation

/// The single-use credentials iTerm2 hands out for one API connection: a cookie and a key.
///
/// Both are validated on creation (non-empty printable ASCII without spaces, at most 512
/// bytes), so they can go into HTTP header lines without any way to inject another header.
public struct ITerm2Credentials: Sendable, Hashable {
  /// The longest cookie or key accepted, in bytes.
  public static let maximumTokenLength = 512

  /// The `x-iterm2-cookie` value.
  public let cookie: String
  /// The `x-iterm2-key` value.
  public let key: String

  /// Creates credentials from their two parts.
  ///
  /// - Throws: `ITerm2Error.protocolError` if either part is empty, too long, or contains
  ///   anything but printable ASCII without spaces.
  public init(cookie: String, key: String) throws {
    guard Self.isValidToken(cookie), Self.isValidToken(key) else {
      throw ITerm2Error.protocolError("iTerm2 returned a malformed cookie and key")
    }
    self.cookie = cookie
    self.key = key
  }

  /// Parses the reply of iTerm2's `request cookie and key` AppleScript command: exactly
  /// `"<cookie> <key>"`, two tokens separated by one space, with nothing before, between or
  /// after them.
  ///
  /// - Throws: `ITerm2Error.protocolError` for any other shape.
  public init(appleScriptReply reply: String) throws {
    let parts = reply.split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 2 else {
      throw ITerm2Error.protocolError("iTerm2 returned a malformed cookie and key")
    }
    try self.init(cookie: String(parts[0]), key: String(parts[1]))
  }

  /// Whether `token` is non-empty, at most `maximumTokenLength` bytes, and made only of
  /// printable ASCII other than space (0x21–0x7E).
  static func isValidToken(_ token: String) -> Bool {
    let bytes = token.utf8
    return !bytes.isEmpty && bytes.count <= maximumTokenLength
      && bytes.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
  }
}

/// Supplies fresh API credentials. Every connection attempt asks for new ones: iTerm2's
/// cookies are single-use.
public protocol ITerm2CookieProvider: Sendable {
  /// Requests a fresh cookie and key. Never launches iTerm2.
  ///
  /// - Throws: `ITerm2Error` (`notRunning`, `automationDenied`, `cookieUnavailable`,
  ///   `protocolError` for a malformed reply).
  func requestCredentials() async throws -> ITerm2Credentials
}

/// The production cookie provider: runs iTerm2's `request cookie and key` AppleScript command
/// in-process with `NSAppleScript` on the main actor.
///
/// The script source is a fixed constant; no runtime value is ever spliced into it (PLAN.md D1).
/// It runs only if iTerm2 is already running, because `tell application` would otherwise launch
/// it. A process started from a shell inside iTerm2 inherits iTerm2's Automation permission, so
/// no prompt appears; the app bundle launched through LaunchServices gets a one-time macOS
/// Automation prompt, during which the main actor waits for the user.
public struct AppleScriptCookieProvider: ITerm2CookieProvider {
  /// The AppleScript source. Static: never build it from runtime values.
  public static let scriptSource =
    #"tell application "iTerm2" to request cookie and key for app named "muxFinder""#

  /// Tells whether iTerm2 is running.
  private let appControl: any ITerm2AppControl

  /// Creates a provider that checks `appControl` before every request.
  public init(appControl: any ITerm2AppControl = WorkspaceITerm2AppControl()) {
    self.appControl = appControl
  }

  /// Runs the script if iTerm2 is running and parses its reply.
  public func requestCredentials() async throws -> ITerm2Credentials {
    guard await appControl.isRunning() else { throw ITerm2Error.notRunning }
    let reply = try await Self.runScript()
    return try ITerm2Credentials(appleScriptReply: reply)
  }

  /// Compiles and runs `scriptSource`, returning its string result.
  @MainActor
  static func runScript() throws -> String {
    guard let script = NSAppleScript(source: scriptSource) else {
      throw ITerm2Error.protocolError("the cookie request script could not be created")
    }
    var errorInfo: NSDictionary?
    let result = script.executeAndReturnError(&errorInfo)
    if let errorInfo {
      let number = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
      throw error(forAppleScriptError: number)
    }
    guard let reply = result.stringValue else {
      throw ITerm2Error.protocolError("iTerm2 returned no cookie and key")
    }
    return reply
  } // End of func runScript()

  /// Maps an AppleScript error number: -1743 (`errAEEventNotPermitted`) and -1744 (consent
  /// would be needed) mean the Automation permission is missing; -600 (`procNotFound`) and
  /// -609 (`connectionInvalid`) mean iTerm2 is not (or no longer) running; -1712 is an Apple
  /// event timeout. Anything else is reported with its number.
  static func error(forAppleScriptError number: Int) -> ITerm2Error {
    switch number {
    case -1743, -1744: return .automationDenied
    case -600, -609: return .notRunning
    case -1712: return .timedOut
    default: return .cookieUnavailable(appleScriptError: number)
    }
  }
}

/// Finds out whether iTerm2 runs, and launches it. Behind a protocol so tests never touch
/// `NSWorkspace`.
public protocol ITerm2AppControl: Sendable {
  /// Whether iTerm2 is running. Never launches it.
  func isRunning() async -> Bool
  /// Launches iTerm2 if it is not running and waits until it has finished launching. Only the
  /// attach path may call this; discovery and every read-only command must not.
  func launch() async throws
}

/// The production `ITerm2AppControl`, built on `NSRunningApplication` and `NSWorkspace` (used on
/// the main actor).
public struct WorkspaceITerm2AppControl: ITerm2AppControl {
  /// iTerm2's bundle identifier.
  public static let bundleIdentifier = "com.googlecode.iterm2"

  /// How long `launch()` waits for iTerm2 to finish launching.
  public var launchTimeout: Duration

  /// Creates the control.
  public init(launchTimeout: Duration = .seconds(30)) {
    self.launchTimeout = launchTimeout
  }

  /// Whether a process with iTerm2's bundle id is running.
  public func isRunning() async -> Bool {
    await MainActor.run { Self.runningInstance() != nil }
  }

  /// Launches iTerm2 through `NSWorkspace` (without bringing it to the front) and waits until
  /// it reports that it finished launching.
  ///
  /// - Throws: `ITerm2Error.launchFailed` if iTerm2 is not installed or `NSWorkspace` fails,
  ///   `ITerm2Error.timedOut` if it does not finish launching within `launchTimeout`.
  public func launch() async throws {
    if await isRunning() { return }
    let url = await MainActor.run {
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
    }
    guard let url else { throw ITerm2Error.launchFailed("iTerm2 is not installed") }
    try await Self.open(url)
    let deadline = ContinuousClock.now + launchTimeout
    while ContinuousClock.now < deadline {
      let finished = await MainActor.run { Self.runningInstance()?.isFinishedLaunching ?? false }
      if finished { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw ITerm2Error.timedOut
  } // End of func launch()

  /// The running iTerm2 instance, if any.
  @MainActor
  private static func runningInstance() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
      .first { !$0.isTerminated }
  }

  /// Asks `NSWorkspace` to open the application at `url` without activating it.
  @MainActor
  private static func open(_ url: URL) async throws {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
        if let error = error as NSError? {
          continuation.resume(
            throwing: ITerm2Error.launchFailed("NSWorkspace error \(error.code)"))
        } else {
          continuation.resume()
        }
      }
    }
  } // End of func open(_:)
}
