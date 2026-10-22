import AppKit
import Foundation
import MuxFinderCore
import MuxFinderUI

/// `--selftest attach-local|new-session-local [--selftest-keep]` (PLAN.md D25): a plain
/// `NSApplication` with no window, menu bar item, popover, onboarding or Settings, running one
/// `SelfTestDriver` over the real iTerm2 and This Mac's default tmux server, and exiting with
/// its status: 0 passed, 1 a step failed or the run was interrupted (cleanup ran), 2 the
/// environment cannot run it (nothing was contacted).
///
/// Before anything contacts iTerm2 it checks that the launch helper sits next to the binary
/// and that `TMUX_TMPDIR` is unset (the launch tab's tmux would use another server).
///
/// SIGTERM and SIGINT during the steps cancel the driver, which cleans up and fails (exit 1).
/// In keep mode, once the attachment is confirmed, the app prints the session name, the
/// connection id and the gateway session id and waits; SIGTERM or SIGINT then quit through
/// `AppTermination` and `applicationShouldTerminate` like the menu bar app (exit 0), leaving
/// the session and the connection in place.
@MainActor
final class SelfTestAppDelegate: NSObject, NSApplicationDelegate {
  /// How long quitting in keep mode waits for the model to stop before exiting anyway: the
  /// menu bar app's deadline (`AppModel.terminationDeadline`), longer than the model's own
  /// budget for the session actions.
  static let shutdownDeadline = AppModel.terminationDeadline

  /// The self-test.
  private let request: SelfTestRequest
  /// The SIGTERM and SIGINT sources.
  private var signalSources: [any DispatchSourceSignal] = []
  /// The driver, once built.
  private var driver: SelfTestDriver?
  /// Runs the driver.
  private var driverTask: Task<Void, Never>?
  /// Whether keep mode is waiting for SIGTERM.
  private var isKeeping = false
  /// Whether quitting already started.
  private var isTerminating = false
  /// Whether AppKit was told it may terminate.
  private var didReplyToTerminate = false

  /// A delegate for `request`.
  private init(request: SelfTestRequest) {
    self.request = request
    super.init()
  }

  /// Runs the self-test app; never returns (the process exits with the self-test's status).
  static func run(request: SelfTestRequest) {
    let app = NSApplication.shared
    let delegate = SelfTestAppDelegate(request: request)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
  }

  /// Checks the environment, then runs the driver.
  func applicationDidFinishLaunching(_ notification: Notification) {
    signalSources = [SIGTERM, SIGINT].map { number in
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { [weak self] in
        MainActor.assumeIsolated { self?.signalReceived() }
      }
      source.resume()
      return source
    }
    if ProcessInfo.processInfo.environment["TMUX_TMPDIR"] != nil {
      fail(
        "TMUX_TMPDIR is set; the launch tab's tmux would use another server. Unset it and run "
          + "again.")
    }
    let helperPath: LaunchHelperPath
    do {
      helperPath = try LaunchHelperPath.locate()
    } catch {
      fail(error.message)
    }
    let driver = SelfTestDriver(request: request, seams: .production(helperPath: helperPath))
    self.driver = driver
    driverTask = Task {
      let outcome = await driver.run()
      finish(outcome)
    }
  } // End of func applicationDidFinishLaunching(_:)

  /// Exits with the outcome's status, or waits for SIGTERM in keep mode.
  private func finish(_ outcome: SelfTestDriver.Outcome) {
    switch outcome {
    case .passed:
      exit(0)
    case .failed:
      exit(1)
    case .kept(let info):
      isKeeping = true
      for line in [info.line] + info.cleanupLines {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
      }
      FileHandle.standardOutput.write(
        Data("muxFinder self-test keep: waiting for SIGTERM (pid \(getpid()))\n".utf8))
    }
  } // End of func finish(_:)

  /// SIGTERM or SIGINT: quits normally in keep mode; otherwise interrupts the steps (the
  /// driver cleans up and fails).
  private func signalReceived() {
    if isKeeping {
      AppTermination.request()
    } else {
      driverTask?.cancel()
    }
  }

  /// Keep mode's quit: stops the model (nothing detached, killed or closed) and replies;
  /// anything else asking to quit while the steps run is refused (the driver ends the run).
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard isKeeping else {
      driverTask?.cancel()
      return .terminateCancel
    }
    guard !isTerminating else { return .terminateLater }
    isTerminating = true
    Task {
      await driver?.shutdown()
      replyToTerminate()
    }
    Task {
      try? await Task.sleep(for: Self.shutdownDeadline)
      replyToTerminate()
    }
    return .terminateLater
  } // End of func applicationShouldTerminate(_:)

  /// Lets AppKit finish terminating, once.
  private func replyToTerminate() {
    guard !didReplyToTerminate else { return }
    didReplyToTerminate = true
    NSApp.reply(toApplicationShouldTerminate: true)
  }

  /// Prints why the self-test cannot run and exits 2; nothing was contacted.
  private func fail(_ reason: String) -> Never {
    FileHandle.standardError.write(Data("muxFinder self-test: \(reason)\n".utf8))
    exit(2)
  }
}
