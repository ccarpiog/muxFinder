import Foundation

/// Why "Set up SSH in iTerm2…" did not open its tab (PLAN.md D24). `message` is English,
/// sentence case, and names no host, destination or path.
public enum SSHSetupFailure: Error, Sendable, Hashable {
  /// The host is This Mac: there is nothing to set up over SSH.
  case notAnSSHHost
  /// The destination failed `Validation.sshDestination(_:)`; nothing was written or started.
  case invalidDestination(ValidationError)
  /// The helper (`muxfinder-launch`) cannot be given to iTerm2.
  case helperUnavailable(LaunchHelperPathError)
  /// The request file could not be written.
  case launchStore(LaunchStoreError)
  /// iTerm2 could not be started, or did not open the tab.
  case iTerm2(ITerm2Error)
  /// The caller was cancelled before the tab was asked for; the request was withdrawn.
  case cancelled

  /// A short machine-readable name, for diagnostics.
  public var kind: String {
    switch self {
    case .notAnSSHHost: return "notAnSSHHost"
    case .invalidDestination: return "invalidDestination"
    case .helperUnavailable: return "helperUnavailable"
    case .launchStore: return "launchStore"
    case .iTerm2(let error): return "iTerm2.\(error.kind)"
    case .cancelled: return "cancelled"
    }
  }

  /// The user-facing explanation.
  public var message: String {
    switch self {
    case .notAnSSHHost:
      return "This Mac is checked directly, so there is no SSH to set up."
    case .invalidDestination(let error):
      return "muxFinder can't open ssh for this host: \(error.message)"
    case .helperUnavailable(let error):
      return error.message
    case .launchStore:
      return "muxFinder couldn't prepare the tab. Try again."
    case .iTerm2(let error):
      return error.errorDescription ?? "iTerm2 didn't open the tab."
    case .cancelled:
      return "Opening the tab was cancelled."
    }
  } // End of var message
}

/// How "Set up SSH in iTerm2…" ended (PLAN.md D24).
public enum SSHSetupResult: Sendable, Hashable {
  /// iTerm2 opened the tab, whose iTerm2 session is `sessionID`; ssh runs in it through the
  /// helper. Whether ssh then connects is for the user to see in the tab.
  case opened(sessionID: String)
  /// No tab was opened.
  case failed(SSHSetupFailure)
}

/// Opens "Set up SSH in iTerm2…" tabs. `SSHSetupLauncher` is the production implementation; the
/// UI's tests pass fakes.
public protocol SSHSetupOpening: Sendable {
  /// Opens a launch tab running plain interactive ssh to `host`'s destination.
  func openSSHSetup(for host: HostConfig) async -> SSHSetupResult
}

/// The request files ssh setup writes (PLAN.md D14, D24). `LaunchStore` is the production
/// implementation.
public protocol SSHSetupRequestStore: Sendable {
  /// Writes a new ssh setup request file; see `LaunchStore.writeRequest(_:)`.
  func writeRequest(_ request: SSHSetupRequest) throws(LaunchStoreError)

  /// Deletes a request that is still there; see `LaunchStore.discardRequest(_:)`.
  @discardableResult
  func discardRequest(_ id: LaunchToken) throws(LaunchStoreError) -> Bool

  /// Removes stale launch files; see `LaunchStore.sweep()`.
  @discardableResult
  func sweep() throws(LaunchStoreError) -> Int
}

extension LaunchStore: SSHSetupRequestStore {}

/// "Set up SSH in iTerm2…" (PLAN.md D24): opens a launch tab whose helper runs plain interactive
/// `/usr/bin/ssh -- <destination>`, so the user can accept a host key or sign in the way they
/// always do. It never runs ssh itself.
///
/// The steps are the attach's launch-tab steps (D15), through the same seams:
/// 1. Refuse anything but an SSH host whose destination passes `Validation.sshDestination(_:)`
///    (no leading `-`, whitespace or control characters) before anything is written, started
///    or contacted; then find the helper.
/// 2. Write an `SSHSetupRequest` (`"kind":"sshSetup"`), which only `muxfinder-launch
///    ssh-setup` takes.
/// 3. `ensureRunning()` (it may launch iTerm2: the user asked for a tab).
/// 4. `CreateTab` through `LaunchTab`: a new window, the host's profile, the command
///    `<helper> ssh-setup <launch id>`, closing when the helper exits.
///
/// Every failure after step 2 withdraws the request, so a tab that starts late runs nothing;
/// a cancelled caller is withdrawn before `ensureRunning()` or `CreateTab` (once `CreateTab` is
/// sent, the tab opens and its session id is returned). Diagnostics record the outcome kind and
/// duration with the host id only: never the destination.
public struct SSHSetupLauncher: SSHSetupOpening {
  /// The iTerm2 backend (the app's shared client).
  private let iTerm2: any ITerm2Integration
  /// Where request files go.
  private let store: any SSHSetupRequestStore
  /// Finds the helper, at each opening (`LaunchHelperPath.locate()` in production).
  private let locateHelper: @Sendable () -> Result<LaunchHelperPath, LaunchHelperPathError>
  /// Timestamps and durations.
  private let clock: any AttachClock
  /// Where outcomes are recorded, if anywhere.
  private let diagnostics: DiagnosticsLog?

  /// A launcher over its seams. Tests pass fakes for each.
  public init(
    iTerm2: any ITerm2Integration,
    store: any SSHSetupRequestStore,
    locateHelper: @escaping @Sendable () -> Result<LaunchHelperPath, LaunchHelperPathError> = {
      SSHSetupLauncher.locateStandardHelper()
    },
    clock: any AttachClock = SystemAttachClock(),
    diagnostics: DiagnosticsLog? = nil
  ) {
    self.iTerm2 = iTerm2
    self.store = store
    self.locateHelper = locateHelper
    self.clock = clock
    self.diagnostics = diagnostics
  } // End of init(iTerm2:store:locateHelper:clock:diagnostics:)

  /// `LaunchHelperPath.locate()` next to the running executable.
  public static func locateStandardHelper() -> Result<LaunchHelperPath, LaunchHelperPathError> {
    do throws(LaunchHelperPathError) {
      return .success(try LaunchHelperPath.locate())
    } catch {
      return .failure(error)
    }
  }

  /// Opens the tab for `host` (see the type's steps) and returns how it went.
  public func openSSHSetup(for host: HostConfig) async -> SSHSetupResult {
    let start = clock.now()
    let result = await open(host)
    await record(result, hostID: host.id, duration: clock.now() - start)
    return result
  }

  /// The steps, without the diagnostics.
  private func open(_ host: HostConfig) async -> SSHSetupResult {
    guard host.mode == .ssh else { return .failed(.notAnSSHHost) }
    let destination: String
    do throws(ValidationError) {
      destination = try Validation.sshDestination(host.sshDestination)
    } catch {
      return .failed(.invalidDestination(error))
    }
    let helper: LaunchHelperPath
    switch locateHelper() {
    case .success(let path): helper = path
    case .failure(let error): return .failed(.helperUnavailable(error))
    }
    guard !Task.isCancelled else { return .failed(.cancelled) }
    _ = try? store.sweep()
    let request = SSHSetupRequest(
      createdAt: clock.date(), hostID: host.id, destination: destination)
    do throws(LaunchStoreError) {
      try store.writeRequest(request)
    } catch {
      return .failed(.launchStore(error))
    }
    guard !Task.isCancelled else { return withdraw(request.id, .cancelled) }
    do {
      try await iTerm2.ensureRunning()
    } catch {
      return withdraw(request.id, Self.failure(for: error))
    }
    guard !Task.isCancelled else { return withdraw(request.id, .cancelled) }
    let tab = LaunchTab.request(
      commandLine: helper.commandLine(for: request.id, kind: .sshSetup),
      profileName: host.iTermProfileName)
    switch await LaunchTab.open(tab, on: iTerm2) {
    case .failure(let error):
      return withdraw(request.id, Self.failure(for: error))
    case .success(let sessionID):
      return .opened(sessionID: sessionID)
    }
  } // End of func open(_:)

  /// Withdraws the request `id` (a tab that starts late then runs nothing) and returns the
  /// failure.
  private func withdraw(_ id: LaunchToken, _ failure: SSHSetupFailure) -> SSHSetupResult {
    _ = try? store.discardRequest(id)
    return .failed(failure)
  }

  /// The failure for an error from iTerm2 (any other error is a cancellation).
  static func failure(for error: any Error) -> SSHSetupFailure {
    if let error = error as? ITerm2Error { return .iTerm2(error) }
    return .cancelled
  }

  /// Records the outcome: its kind and duration, with the host id only.
  private func record(_ result: SSHSetupResult, hostID: UUID, duration: Duration) async {
    guard let diagnostics else { return }
    let milliseconds = Int(duration / .milliseconds(1))
    switch result {
    case .opened:
      await diagnostics.record(
        .launch, outcome: .success, hostID: hostID.uuidString, durationMs: milliseconds,
        detail: "ssh setup tab opened")
    case .failed(let failure):
      await diagnostics.record(
        .launch, outcome: failure == .cancelled ? .cancelled : .failure,
        hostID: hostID.uuidString, durationMs: milliseconds,
        detail: "ssh setup tab not opened: \(failure.kind)")
    }
  } // End of func record(_:hostID:duration:)
}
