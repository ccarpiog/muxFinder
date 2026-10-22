import Foundation
import MuxFinderCore
import Observation

/// Where one host's "Set up SSH in iTerm2…" stands (PLAN.md D24), and the line shown for it.
/// The result is shown honestly: "opened" says only that iTerm2 opened the tab, never that ssh
/// connected.
public enum SSHSetupState: Sendable, Hashable {
  /// muxFinder is asking iTerm2 for the tab.
  case opening
  /// iTerm2 opened the tab; ssh runs in it.
  case opened
  /// No tab was opened, for this reason.
  case failed(SSHSetupFailure)

  /// The state for a launcher's result.
  public init(_ result: SSHSetupResult) {
    switch result {
    case .opened: self = .opened
    case .failed(let failure): self = .failed(failure)
    }
  }

  /// The line shown next to the button.
  public var message: String {
    switch self {
    case .opening:
      return "Opening a new iTerm2 window…"
    case .opened:
      return "iTerm2 opened a new window running ssh to this host. Sign in or answer the host "
        + "key question there, then check the host again."
    case .failed(let failure):
      return "muxFinder couldn't open ssh in iTerm2. " + failure.message
    }
  } // End of var message

  /// Whether the line reports a problem.
  public var isProblem: Bool {
    if case .failed = self { return true }
    return false
  }

  /// The fix-it for an iTerm2 error, if the failure has one.
  public var fixIt: FixIt? {
    if case .failed(.iTerm2(let error)) = self { return FixIt(error: error) }
    return nil
  }
}

/// "Set up SSH in iTerm2…" for one window's hosts (PLAN.md D24): the onboarding window, the
/// Settings host editor and the popover each own one. It asks the `SSHSetupOpening` seam
/// (`SSHSetupLauncher` in production) to open the tab, one request per host at a time while
/// its line shows, and keeps each host's `SSHSetupState`.
///
/// Nothing runs until `open(_:)`: no tab is opened, no iTerm2 contacted and no ssh started on
/// its own. Each line waits for one request's result only: `clear(_:)` (the destination or
/// mode changed, or the host was checked again) forgets the line and drops that request's
/// result, so a result is never shown under values it was not asked for. `cancelAll()` (the
/// window closed) cancels requests still running (a request cancelled before `CreateTab` is
/// withdrawn, so no tab opens) and forgets every line. A cancelled or dropped request may
/// still run for a while (once `CreateTab` was sent, the launcher waits for iTerm2's answer),
/// so every request stays owned here until it ends, whatever became of its line, and
/// `shutdown()` (quitting) cancels them all and waits for every one to end.
@MainActor
@Observable
public final class SSHSetupActions {
  /// Each host's state, by host id.
  public private(set) var states: [UUID: SSHSetupState]

  /// Opens the tabs; `nil` offers no action.
  @ObservationIgnored private let opener: (any SSHSetupOpening)?
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

  /// Actions over `opener`, starting with `states` (fixtures show some).
  public init(opener: (any SSHSetupOpening)?, states: [UUID: SSHSetupState] = [:]) {
    self.opener = opener
    self.states = states
  }

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

  /// Opens the tab for `host` (as it stands: a draft's values work too). Ignored while the
  /// host's line shows a request running, for a host the action is not offered for, without
  /// an opener, and after `shutdown()`.
  public func open(_ host: HostConfig) {
    guard let opener, !isShutDown, Self.isOffered(for: host), !isOpening(host.id) else {
      return
    }
    lastRequestNumber += 1
    let number = lastRequestNumber
    states[host.id] = .opening
    awaitedRequests[host.id] = number
    unfinished[number] = Task { [weak self] in
      let result = await opener.openSSHSetup(for: host)
      self?.finish(number, hostID: host.id, result: result)
    }
  } // End of func open(_:)

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
  }

  /// The window closed: cancels every request still running and forgets every line. The
  /// requests stay owned until they end (`shutdown()` waits for them).
  public func cancelAll() {
    for task in unfinished.values { task.cancel() }
    awaitedRequests = [:]
    states = [:]
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
