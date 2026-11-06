import Foundation
import MuxFinderCore
import Observation

/// Where one host's "Set up SSH in iTerm2…" stands (PLAN.md D24), and the line shown for it.
/// The result is shown honestly: "opened" says only that the terminal opened the tab or window,
/// never that ssh connected. The line names the terminal the request was made in
/// (`message(in:)`, PLAN.md D38, Phase I-12d1); `message` is iTerm2's.
public enum SSHSetupState: Sendable, Hashable {
  /// muxFinder is asking the terminal for the tab or window.
  case opening
  /// The terminal opened the tab or window; ssh runs in it.
  case opened
  /// No tab or window was opened, for this reason.
  case failed(SSHSetupFailure)

  /// The state for a launcher's result (iTerm2's tab or a plain terminal's window).
  public init(_ result: SSHSetupResult) {
    switch result {
    case .opened, .openedWindow: self = .opened
    case .failed(let failure): self = .failed(failure)
    }
  }

  /// The line shown next to the button, for iTerm2 (`message(in: .iTerm2)`).
  public var message: String { message(in: .iTerm2) }

  /// The line shown next to the button, naming the terminal of `wording`.
  public func message(in wording: TerminalWording) -> String {
    switch self {
    case .opening: return wording.sshSetupOpening
    case .opened: return wording.sshSetupOpened
    // The setting not read yet: no terminal to name (PLAN.md D38, Phase I-12d1).
    case .failed(.notUsedWithThisTerminal): return SSHSetupFailure.notUsedWithThisTerminal.message
    case .failed(let failure): return wording.sshSetupFailedPrefix + failure.message
    }
  }

  /// Whether the line reports a problem.
  public var isProblem: Bool {
    if case .failed = self { return true }
    return false
  }

  /// The fix-it for an iTerm2 error, or System Settings › Privacy & Security › Automation for
  /// a plain terminal that may not be controlled, if the failure has one.
  public var fixIt: FixIt? {
    switch self {
    case .failed(.iTerm2(let error)): return FixIt(error: error)
    case .failed(.terminalWindow(.permissionDenied)): return .openAutomationSettings
    default: return nil
    }
  }
} // End of enum SSHSetupState

/// "Set up SSH in iTerm2…" for one window's hosts (PLAN.md D24): the onboarding window, the
/// Settings host editor and the popover each own one. It asks the `SSHSetupOpening` seam
/// (`SSHSetupLauncher` in production) to open the tab, one request per host at a time while
/// its line shows, and keeps each host's `SSHSetupState`. With a plain terminal chosen (PLAN.md
/// D38, Phase I-12d1) it asks that terminal's opener instead (`PlainSSHSetupLauncher`, a window
/// of the chosen terminal), and each line names the terminal its request was made in
/// (`wording(for:)`).
///
/// Nothing runs until `open(_:)`: no tab or window is opened, no terminal contacted and no ssh
/// started on its own. Each line waits for one request's result only: `clear(_:)` (the
/// destination or mode changed, or the host was checked again) forgets the line and drops that
/// request's result, so a result is never shown under values it was not asked for.
/// `cancelAll()` (the window closed) cancels requests still running (a request cancelled before
/// `CreateTab` or the window's open is withdrawn, so nothing opens) and forgets every line. A
/// cancelled or dropped request may still run for a while (once `CreateTab` was sent, the
/// launcher waits for iTerm2's answer), so every request stays owned here until it ends,
/// whatever became of its line, and `shutdown()` (quitting) cancels them all and waits for
/// every one to end.
@MainActor
@Observable
public final class SSHSetupActions {
  /// Makes the opener of a plain terminal's windows for its loaded definition
  /// (`PlainSSHSetupLauncher` in production).
  public typealias PlainOpenerMaker =
    @MainActor @Sendable (LoadedTerminalDefinition) -> any SSHSetupOpening

  /// Each host's state, by host id.
  public private(set) var states: [UUID: SSHSetupState]
  /// The terminal each host's line is about, by host id (the one its request was made in);
  /// a line without one is iTerm2's.
  public private(set) var wordings: [UUID: TerminalWording]
  /// The terminal choice as `AppModel` last resolved it (PLAN.md D38; set through
  /// `setTerminal(_:wording:)`; iTerm2 for a model without one). `unresolved` refuses with
  /// `notUsedWithThisTerminal` ("Still reading the terminal setting…"), an unavailable choice
  /// with `terminalUnavailable`; a plain choice opens a window of its terminal when a plain
  /// opener is wired (else `notUsedWithThisTerminal`, as before Phase I-12d1).
  public private(set) var terminal = TerminalChoiceResolution.iTerm2
  /// The chosen terminal's wording: what a new request's line names.
  public private(set) var wording = TerminalWording.iTerm2
  /// Whether iTerm2 is the chosen terminal (PLAN.md D38, Phase I-12c3a): only then is the
  /// iTerm2 opener asked. False too while the choice is not resolved yet.
  public var usesITerm2: Bool { terminal.usesITerm2 }

  /// Opens iTerm2's tabs; `nil` (with no plain opener either) offers no action.
  @ObservationIgnored private let opener: (any SSHSetupOpening)?
  /// Makes a plain terminal's opener; `nil` leaves a plain choice refused as before Phase
  /// I-12d1 (the tests of other parts).
  @ObservationIgnored private let plainOpener: PlainOpenerMaker?
  /// Every request not ended yet, by request number, including those cancelled by
  /// `cancelAll()` or dropped by `clear(_:)`; each removes itself when it ends.
  @ObservationIgnored private var unfinished: [Int: Task<Void, Never>] = [:]
  /// The number of the request whose result each host's line waits for, by host id.
  /// `clear(_:)` and `cancelAll()` remove entries, so a request started before publishes
  /// nothing.
  @ObservationIgnored private var awaitedRequests: [UUID: Int] = [:]
  /// The last number given to a request.
  @ObservationIgnored private var lastRequestNumber = 0
  /// Whether `shutdown()` ran: nothing new starts.
  @ObservationIgnored private var isShutDown = false

  /// Actions over `opener` (iTerm2's) and `plainOpener` (a plain terminal's), starting with
  /// `states` whose lines name `wordings`' terminals (fixtures show some).
  public init(
    opener: (any SSHSetupOpening)?,
    plainOpener: PlainOpenerMaker? = nil,
    states: [UUID: SSHSetupState] = [:],
    wordings: [UUID: TerminalWording] = [:]
  ) {
    self.opener = opener
    self.plainOpener = plainOpener
    self.states = states
    self.wordings = wordings
  } // End of init(opener:plainOpener:states:wordings:)

  /// Whether the action is offered for `host`: an SSH host whose destination passes
  /// `Validation.sshDestination(_:)`. (Without an opener the button shows but does nothing,
  /// as in previews.)
  nonisolated public static func isOffered(for host: HostConfig) -> Bool {
    host.mode == .ssh && (try? Validation.sshDestination(host.sshDestination)) != nil
  }

  /// Whether `id`'s line shows a request running (a request its line no longer waits for may
  /// still run).
  public func isOpening(_ id: UUID) -> Bool {
    states[id] == .opening
  }

  /// The terminal `id`'s line names: the one its request was made in, else iTerm2.
  public func wording(for id: UUID) -> TerminalWording {
    wordings[id] ?? .iTerm2
  }

  /// `id`'s line, naming the terminal its request was made in; `nil` without a line.
  public func message(for id: UUID) -> String? {
    states[id]?.message(in: wording(for: id))
  }

  /// Opens the tab or window for `host` (as it stands: a draft's values work too). Ignored
  /// while the host's line shows a request running, for a host the action is not offered for,
  /// without any opener, and after `shutdown()`. Which opener is asked follows `terminal`:
  /// iTerm2's for iTerm2 (nothing without it, as before); the plain terminal's for a plain
  /// choice. Nothing is asked of any opener while the choice is not resolved yet
  /// (`notUsedWithThisTerminal`), while it is unavailable (`terminalUnavailable`), or for a
  /// plain choice with no plain opener wired (`notUsedWithThisTerminal`).
  public func open(_ host: HostConfig) {
    guard opener != nil || plainOpener != nil, !isShutDown, Self.isOffered(for: host),
      !isOpening(host.id)
    else { return }
    let chosen: any SSHSetupOpening
    switch terminal {
    case .iTerm2:
      guard let opener else { return }
      chosen = opener
    case .plain(let loaded):
      guard let plainOpener else { return refuse(host.id, .notUsedWithThisTerminal) }
      chosen = plainOpener(loaded)
    case .unresolved:
      return refuse(host.id, .notUsedWithThisTerminal)
    case .unavailable(let failure):
      return refuse(host.id, .terminalUnavailable(failure))
    }
    lastRequestNumber += 1
    let number = lastRequestNumber
    states[host.id] = .opening
    wordings[host.id] = wording
    awaitedRequests[host.id] = number
    unfinished[number] = Task { [weak self] in
      let result = await chosen.openSSHSetup(for: host)
      self?.finish(number, hostID: host.id, result: result)
    }
  } // End of func open(_:)

  /// Shows `failure` as `id`'s line with nothing asked of any opener.
  private func refuse(_ id: UUID, _ failure: SSHSetupFailure) {
    awaitedRequests[id] = nil
    states[id] = .failed(failure)
    wordings[id] = wording
  }

  /// Follows the terminal choice (`AppModel`, PLAN.md D38): `resolution` decides which opener
  /// `open(_:)` asks, `wording` what new lines name. Once the choice changes, every line that
  /// refused for the previous choice (`notUsedWithThisTerminal`, `terminalUnavailable`) is
  /// cleared, so the action is offered again as it was; other lines stay as they are.
  func setTerminal(_ resolution: TerminalChoiceResolution, wording: TerminalWording) {
    let changed = resolution != terminal
    terminal = resolution
    self.wording = wording
    guard changed else { return }
    for (id, state) in states where Self.isChoiceRefusal(state) {
      states[id] = nil
      wordings[id] = nil
    }
  } // End of func setTerminal(_:wording:)

  /// Whether `state` refused because of the terminal choice.
  private static func isChoiceRefusal(_ state: SSHSetupState) -> Bool {
    switch state {
    case .failed(.notUsedWithThisTerminal), .failed(.terminalUnavailable): return true
    default: return false
    }
  }

  /// Request `number` for `hostID` ended with `result`: it is no longer owned, and its result
  /// becomes the host's line only if the line still waits for it.
  private func finish(_ number: Int, hostID: UUID, result: SSHSetupResult) {
    unfinished[number] = nil
    guard awaitedRequests[hostID] == number else { return }
    awaitedRequests[hostID] = nil
    states[hostID] = SSHSetupState(result)
  }

  /// Forgets `id`'s line (its destination or mode changed, or the host was checked again). A
  /// request still running for it goes on, but its result is dropped: it was asked for values
  /// that no longer hold. A new request may start at once.
  public func clear(_ id: UUID) {
    awaitedRequests[id] = nil
    states[id] = nil
    wordings[id] = nil
  }

  /// The window closed: cancels every request still running and forgets every line. The
  /// requests stay owned until they end (`shutdown()` waits for them).
  public func cancelAll() {
    for task in unfinished.values { task.cancel() }
    awaitedRequests = [:]
    states = [:]
    wordings = [:]
  }

  /// Quitting: refuses new requests, cancels every one still running (those of a closed window
  /// or a forgotten line too) and returns once all have ended. Later calls only wait again.
  public func shutdown() async {
    isShutDown = true
    cancelAll()
    await requestsFinished()
  }

  /// Returns once every request started so far has ended.
  func requestsFinished() async {
    while let request = unfinished.first {
      await request.value.value
      unfinished[request.key] = nil
    }
  }
}
