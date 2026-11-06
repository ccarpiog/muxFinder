import Foundation

/// The window half "Set up SSH in <terminal>…" needs from the plain window layer (PLAN.md D24,
/// D38, Phase I-12d1): a new window running the helper's `ssh-setup` mode, and the layer's run
/// policy. The app passes `PlainTerminalWindows`; tests pass `FakePlainTerminalWindowLayer`.
/// Main actor, as the layer is.
@MainActor
public protocol PlainSSHSetupWindowOpening: AnyObject, Sendable {
  /// `PlainTerminalWindows.openSSHSetup(_:helperPath:token:)`: opens a window of `loaded`'s app
  /// running `<helperPath> ssh-setup <token>`.
  func openSSHSetup(
    _ loaded: LoadedTerminalDefinition,
    helperPath: String,
    token: LaunchToken
  ) throws(PlainTerminalWindowError) -> PlainTerminalWindow

  /// `PlainTerminalWindows.checkRunPolicy(for:)`: the layer's run policy for `loaded`'s app,
  /// asked right before the request is written (`unattendedRunRefused` refuses it).
  func checkRunPolicy(for loaded: LoadedTerminalDefinition) throws(PlainTerminalWindowError)
}

/// "Set up SSH in <terminal>…" in a plain terminal (PLAN.md D24, D38, Phase I-12d1): opens a new
/// window of the chosen terminal app whose helper runs plain interactive `/usr/bin/ssh --
/// <destination>`, so the user can accept a host key or sign in the way they always do. It never
/// runs ssh itself, and it never contacts iTerm2.
///
/// The steps are `SSHSetupLauncher`'s with the plain window layer in place of iTerm2's tab:
/// 1. Refuse anything but an SSH host whose destination passes `Validation.sshDestination(_:)`
///    before anything is written, opened or contacted; then find the helper.
/// 2. Ask the window layer's run policy (nothing for the app's `interactive` layer).
/// 3. Write D24's `SSHSetupRequest` unchanged (`"kind":"sshSetup"`), which only `muxfinder-launch
///    ssh-setup` takes.
/// 4. Open the window through the layer (`openSSHSetup`): the same facts gate, compile-once
///    script or spawn, and window record as an attach's open. There is no confirmation: the
///    window's open is the result.
///
/// Every failure after step 3 withdraws the request, so a window that starts late runs nothing;
/// a cancelled caller is withdrawn before the open, cancellation being checked once more on the
/// main actor right before the window opens (closing Settings or onboarding, or quitting, may
/// cancel while the open waits for the main actor). Diagnostics record the outcome kind and
/// duration with the host id only: never the destination.
public struct PlainSSHSetupLauncher: SSHSetupOpening {
  /// The chosen terminal's loaded definition.
  public let loaded: LoadedTerminalDefinition
  /// The plain window layer (the app's one `PlainTerminalWindows`).
  private let windows: any PlainSSHSetupWindowOpening
  /// Where request files go.
  private let store: any SSHSetupRequestStore
  /// Finds the helper, at each opening (`LaunchHelperPath.locate()` in production).
  private let locateHelper: @Sendable () -> Result<LaunchHelperPath, LaunchHelperPathError>
  /// Timestamps and durations.
  private let clock: any AttachClock
  /// Where outcomes are recorded, if anywhere.
  private let diagnostics: DiagnosticsLog?

  /// A launcher for `loaded`'s app over its seams. Tests pass fakes for each.
  public init(
    loaded: LoadedTerminalDefinition,
    windows: any PlainSSHSetupWindowOpening,
    store: any SSHSetupRequestStore,
    locateHelper: @escaping @Sendable () -> Result<LaunchHelperPath, LaunchHelperPathError> = {
      SSHSetupLauncher.locateStandardHelper()
    },
    clock: any AttachClock = SystemAttachClock(),
    diagnostics: DiagnosticsLog? = nil
  ) {
    self.loaded = loaded
    self.windows = windows
    self.store = store
    self.locateHelper = locateHelper
    self.clock = clock
    self.diagnostics = diagnostics
  } // End of init(loaded:windows:store:locateHelper:clock:diagnostics:)

  /// Opens the window for `host` (see the type's steps) and returns how it went.
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
    if let refusal = await runPolicyRefusal() { return .failed(.terminalWindow(refusal)) }
    _ = try? store.sweep()
    let request = SSHSetupRequest(
      createdAt: clock.date(), hostID: host.id, destination: destination)
    do throws(LaunchStoreError) {
      try store.writeRequest(request)
    } catch {
      return .failed(.launchStore(error))
    }
    guard !Task.isCancelled else { return withdraw(request.id, .cancelled) }
    switch await openWindow(helperPath: helper.path, token: request.id) {
    case .cancelled:
      return withdraw(request.id, .cancelled)
    case .failed(let error):
      return withdraw(request.id, .terminalWindow(error))
    case .opened(let window):
      return .openedWindow(window)
    }
  } // End of func open(_:)

  /// How the main actor's part of the opening went.
  private enum WindowOpening: Sendable {
    /// The window opened.
    case opened(PlainTerminalWindow)
    /// The layer refused or failed.
    case failed(PlainTerminalWindowError)
    /// The caller was cancelled before the open: nothing was opened.
    case cancelled
  }

  /// Opens the window on the main actor, through the layer, unless the caller was cancelled
  /// meanwhile: checked there, right before the open, since a cancellation can land after the
  /// caller's own check while this waits for the main actor.
  private func openWindow(helperPath: String, token: LaunchToken) async -> WindowOpening {
    let windows = self.windows
    let loaded = self.loaded
    return await MainActor.run { () -> WindowOpening in
      guard !Task.isCancelled else { return .cancelled }
      do throws(PlainTerminalWindowError) {
        return .opened(try windows.openSSHSetup(loaded, helperPath: helperPath, token: token))
      } catch {
        return .failed(error)
      }
    }
  } // End of func openWindow(helperPath:token:)

  /// The window layer's run policy for this definition, on the main actor: its refusal, or
  /// `nil` when the opening may go on (always for the app's `interactive` layer).
  private func runPolicyRefusal() async -> PlainTerminalWindowError? {
    let windows = self.windows
    let loaded = self.loaded
    return await MainActor.run { () -> PlainTerminalWindowError? in
      do throws(PlainTerminalWindowError) {
        try windows.checkRunPolicy(for: loaded)
        return nil
      } catch {
        return error
      }
    }
  } // End of func runPolicyRefusal()

  /// Withdraws the request `id` (a window that starts late then runs nothing) and returns the
  /// failure.
  private func withdraw(_ id: LaunchToken, _ failure: SSHSetupFailure) -> SSHSetupResult {
    _ = try? store.discardRequest(id)
    return .failed(failure)
  }

  /// Records the outcome: its kind and duration, with the host id and the definition's id only.
  private func record(_ result: SSHSetupResult, hostID: UUID, duration: Duration) async {
    guard let diagnostics else { return }
    let milliseconds = Int(duration / .milliseconds(1))
    let terminal = loaded.definition.id
    switch result {
    case .opened, .openedWindow:
      await diagnostics.record(
        .launch, outcome: .success, hostID: hostID.uuidString, durationMs: milliseconds,
        detail: "ssh setup window opened in \(terminal)")
    case .failed(let failure):
      await diagnostics.record(
        .launch, outcome: failure == .cancelled ? .cancelled : .failure,
        hostID: hostID.uuidString, durationMs: milliseconds,
        detail: "ssh setup window not opened in \(terminal): \(failure.kind)")
    }
  } // End of func record(_:hostID:duration:)
} // End of struct PlainSSHSetupLauncher
