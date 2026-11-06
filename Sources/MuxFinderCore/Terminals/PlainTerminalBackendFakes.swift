import Foundation

/// A window layer for tests and previews (PLAN.md D38, Phase I-12c1): it opens and focuses
/// nothing of any terminal app, records every open and focus, and answers the failures set by
/// the test. After an open that succeeds it runs `onOpen` with the launch token, so a test can
/// play the helper (write its early report or result) or start a real helper on a
/// pseudo-terminal of its own. No Apple event, no compile, no app launched.
@MainActor
public final class FakePlainTerminalWindowLayer: PlainTerminalWindowLayer {
  /// One recorded open.
  public struct Open: Sendable, Hashable {
    /// The id of the definition the open was for.
    public let definitionID: String
    /// The helper path the window would run.
    public let helperPath: String
    /// The launch token the window would pass the helper.
    public let token: LaunchToken
  }

  /// Every open, in order (failed ones too).
  public private(set) var opens: [Open] = []
  /// Every window a focus was asked for, in order (failed ones too).
  public private(set) var focuses: [PlainTerminalWindow] = []
  /// When set, every open fails with it (still recorded; `onOpen` does not run).
  public var openFailure: PlainTerminalWindowError?
  /// When set, every focus fails with it (still recorded).
  public var focusFailure: PlainTerminalWindowError?
  /// The terminal device every opened window reports (`nil`, as an `exec` window or Ghostty).
  public var tty: String?
  /// Runs after each open that succeeds, with the launch token; its error fails that open.
  public var onOpen: (@MainActor (LaunchToken) throws(PlainTerminalWindowError) -> Void)?
  /// How many run policy checks were asked for.
  public private(set) var runPolicyChecks = 0
  /// When set, every run policy check fails with it (still counted).
  public var runPolicyFailure: PlainTerminalWindowError?

  /// A layer with no failures and no hook.
  public init() {}

  /// Records the open, then fails with `openFailure`, or runs `onOpen` and answers a window
  /// `fake-window-<n>` (the n-th open) with `tty`.
  public func open(
    _ loaded: LoadedTerminalDefinition,
    helperPath: String,
    token: LaunchToken
  ) throws(PlainTerminalWindowError) -> PlainTerminalWindow {
    opens.append(Open(definitionID: loaded.definition.id, helperPath: helperPath, token: token))
    if let openFailure { throw openFailure }
    try onOpen?(token)
    return PlainTerminalWindow(openedBy: loaded, windowID: "fake-window-\(opens.count)", tty: tty)
  } // End of func open(_:helperPath:token:)

  /// Records the focus, then refuses a window `loaded` did not open (as the real layer does,
  /// before anything else), or fails with `focusFailure`.
  public func focus(
    _ window: PlainTerminalWindow,
    of loaded: LoadedTerminalDefinition
  ) throws(PlainTerminalWindowError) {
    focuses.append(window)
    guard window.definitionID == loaded.definition.id else { throw .windowOfAnotherTerminal }
    guard window.openedBy == loaded else {
      throw .definitionChanged(appName: window.openedBy.definition.displayName)
    }
    if let focusFailure { throw focusFailure }
  } // End of func focus(_:of:)

  /// Counts the check, then fails with `runPolicyFailure` if one is set.
  public func checkRunPolicy(
    for loaded: LoadedTerminalDefinition
  ) throws(PlainTerminalWindowError) {
    runPolicyChecks += 1
    if let runPolicyFailure { throw runPolicyFailure }
  }

  // MARK: - Close (Phase I-12c3b, `e2e-plain`'s seam)

  /// Every window a close was asked for, in order (failed ones too).
  public private(set) var closes: [PlainTerminalWindow] = []
  /// The windows closed, in order.
  public private(set) var closed: [PlainTerminalWindow] = []
  /// When set, every close fails with it (still recorded; `onClose` does not run).
  public var closeFailure: PlainTerminalWindowError?
  /// Runs for each close that would succeed, before the window counts as closed; its error
  /// fails that close (so a test can check, at the moment of the close, what the window ran).
  public var onClose: (@MainActor (PlainTerminalWindow) throws(PlainTerminalWindowError) -> Void)?

  /// Records the close, then refuses (as the real layer does, with nothing else done) a window
  /// `loaded` did not open, one with no id, one this layer did not open or already closed
  /// (`notOpenedHere`), or fails with `closeFailure`; else runs `onClose` and records the
  /// window closed.
  public func close(
    _ window: PlainTerminalWindow,
    of loaded: LoadedTerminalDefinition
  ) throws(PlainTerminalWindowError) {
    closes.append(window)
    guard window.definitionID == loaded.definition.id else { throw .windowOfAnotherTerminal }
    guard window.openedBy == loaded else {
      throw .definitionChanged(appName: window.openedBy.definition.displayName)
    }
    guard let windowID = window.windowID else {
      throw .windowHasNoID(appName: loaded.definition.displayName)
    }
    let openedHere = opens.indices.contains { "fake-window-\($0 + 1)" == windowID }
    guard openedHere, !closed.contains(window) else { throw .notOpenedHere }
    if let closeFailure { throw closeFailure }
    try onClose?(window)
    closed.append(window)
  } // End of func close(_:of:)
} // End of class FakePlainTerminalWindowLayer

/// `e2e-plain`'s close seam (Phase I-12c3b). Declared here, next to the class, since the
/// protocol is `Sendable`.
extension FakePlainTerminalWindowLayer: PlainTerminalWindowClosing {}
