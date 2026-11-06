import Foundation
import Testing
import os

@testable import MuxFinderCore

/// "Set up SSH in <terminal>…" in a plain terminal (PLAN.md D24, D38, Phase I-12d1): the
/// launcher writes D24's request unchanged and opens one window of the chosen terminal through
/// the window layer (`openSSHSetup`, the helper's `ssh-setup` mode), never contacting iTerm2.
/// Over `FakePlainTerminalWindowLayer` and a real launch store in a temporary folder; the real
/// window layer only over its fakes (no script compiled, no Apple event, no app launched).
@Suite("Plain SSH setup")
@MainActor
struct PlainSSHSetupLauncherTests {
  /// The helper path every opening uses.
  static let helper = "/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch"
  /// The host's id.
  static let hostID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

  /// The launcher, its fakes and its store.
  struct Fixture {
    /// The launcher.
    let launcher: PlainSSHSetupLauncher
    /// The window layer.
    let windows: FakePlainTerminalWindowLayer
    /// The real store, in a temporary folder.
    let store: LaunchStore
    /// The diagnostics log.
    let log: DiagnosticsLog
    /// The temporary root to remove.
    let root: URL
  }

  /// The built-in Terminal definition, loaded as text from the repository.
  static func terminal() throws -> LoadedTerminalDefinition {
    try #require(
      TerminalDefinitionTestSupport.load(builtIn: TerminalDefinitionTestSupport.builtInDirectory)
        .definition(withID: "terminal"))
  }

  /// A launcher for Terminal over a fake window layer and a real store; `helperAvailable`
  /// false stands for a missing helper.
  static func fixture(helperAvailable: Bool = true) throws -> Fixture {
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    let windows = FakePlainTerminalWindowLayer()
    let helper = try LaunchHelperPath(validating: Self.helper)
    let log = DiagnosticsLog(writesToSystemLog: false)
    let launcher = PlainSSHSetupLauncher(
      loaded: try terminal(), windows: windows, store: store,
      locateHelper: { helperAvailable ? .success(helper) : .failure(.notFound) },
      diagnostics: log)
    return Fixture(launcher: launcher, windows: windows, store: store, log: log, root: root)
  } // End of static func fixture(helperAvailable:)

  /// An SSH host with `destination`.
  static func host(_ destination: String) -> HostConfig {
    HostConfig(
      id: hostID, displayName: "Saturno", mode: .ssh, sshDestination: destination,
      iTermProfileName: "Work", isEnabled: false)
  }

  /// The request files in the store's folder.
  static func requestFiles(_ store: LaunchStore) throws -> [String] {
    try LaunchTestSupport.names(in: store.directory).filter { $0.hasSuffix(".request.json") }
  }

  /// The plain path: D24's request with the destination, then exactly one window open of the
  /// chosen terminal with the helper path and the request's id; the result is that window,
  /// the request stays for the helper, and the log names neither the destination nor a path.
  @Test func writesTheRequestAndOpensOneWindow() async throws {
    let fixture = try Self.fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let result = await fixture.launcher.openSSHSetup(for: Self.host("admin@saturno.example"))
    let open = try #require(fixture.windows.sshSetupOpens.first)
    #expect(fixture.windows.sshSetupOpens.count == 1)
    #expect(fixture.windows.opens.isEmpty, "no attach window")
    #expect(open.definitionID == "terminal" && open.helperPath == Self.helper)
    #expect(fixture.windows.runPolicyChecks == 1)
    guard case .openedWindow(let window) = result else {
      Issue.record("not opened: \(result)")
      return
    }
    #expect(window.definitionID == "terminal" && window.windowID == "fake-ssh-window-1")
    #expect(try Self.requestFiles(fixture.store) == ["\(open.token.rawValue).request.json"])
    let request = try fixture.store.takeSSHSetupRequest(open.token)
    #expect(request.destination == "admin@saturno.example" && request.hostID == Self.hostID)
    #expect(request.kind == .sshSetup)
    let detail = try #require(await fixture.log.events().last?.detail)
    #expect(detail == "ssh setup window opened in terminal")
    #expect(!detail.contains("saturno") && !detail.contains("/Applications"))
  } // End of func writesTheRequestAndOpensOneWindow()

  /// A window that could not be opened withdraws the request (a window starting late runs
  /// nothing) and answers the window layer's failure.
  @Test func aFailedOpenWithdrawsTheRequest() async throws {
    let fixture = try Self.fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    fixture.windows.openFailure = .permissionDenied(appName: "Terminal")
    let result = await fixture.launcher.openSSHSetup(for: Self.host("saturno.example"))
    #expect(result == .failed(.terminalWindow(.permissionDenied(appName: "Terminal"))))
    #expect(fixture.windows.sshSetupOpens.count == 1)
    #expect(try Self.requestFiles(fixture.store).isEmpty)
    #expect(
      SSHSetupFailure.terminalWindow(.permissionDenied(appName: "Terminal")).kind
        == "terminalWindow.permissionDenied")
  } // End of func aFailedOpenWithdrawsTheRequest()

  /// A cancellation that lands after the launcher's own check, while its open waits for the
  /// main actor (closing Settings or onboarding, or quitting), opens no window and withdraws the
  /// request. Right after the request is written, the store holds the main actor for 0.3 s (the
  /// launcher passes its check and queues its open behind it meanwhile), then cancels the
  /// launcher's task there, so the open runs only after the cancellation.
  @Test func aCancellationWhileTheOpenWaitsForTheMainActorOpensNothing() async throws {
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    let windows = FakePlainTerminalWindowLayer()
    let canceller = TaskCanceller()
    let holding = MainActorHoldingStore(base: store) {
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          Thread.sleep(forTimeInterval: 0.3)
          canceller.cancel()
        }
      }
    }
    let helper = try LaunchHelperPath(validating: Self.helper)
    let log = DiagnosticsLog(writesToSystemLog: false)
    let launcher = PlainSSHSetupLauncher(
      loaded: try Self.terminal(), windows: windows, store: holding,
      locateHelper: { .success(helper) }, diagnostics: log)
    let host = Self.host("saturno.example")
    let task = Task.detached { await launcher.openSSHSetup(for: host) }
    canceller.task = task
    let result = await task.value
    #expect(result == .failed(.cancelled))
    #expect(windows.sshSetupOpens.isEmpty, "no window opened after the cancellation")
    #expect(windows.runPolicyChecks == 1 && holding.writes == 1)
    #expect(try Self.requestFiles(store).isEmpty, "the request withdrawn")
    #expect(await log.events().last?.outcome == .cancelled)
  } // End of func aCancellationWhileTheOpenWaitsForTheMainActorOpensNothing()

  /// Refusals before anything: This Mac, an unusable destination, a missing helper and the
  /// window layer's run policy write no request and open no window.
  @Test func refusesBeforeWritingOrOpening() async throws {
    let fixture = try Self.fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var local = Self.host("")
    local.mode = .local
    #expect(await fixture.launcher.openSSHSetup(for: local) == .failed(.notAnSSHHost))
    let invalid = await fixture.launcher.openSSHSetup(for: Self.host("-oProxyCommand=x"))
    guard case .failed(.invalidDestination) = invalid else {
      Issue.record("not refused: \(invalid)")
      return
    }
    let missing = try Self.fixture(helperAvailable: false)
    defer { try? FileManager.default.removeItem(at: missing.root) }
    #expect(
      await missing.launcher.openSSHSetup(for: Self.host("saturno.example"))
        == .failed(.helperUnavailable(.notFound)))
    fixture.windows.runPolicyFailure = .appNotRunning(appName: "Terminal")
    #expect(
      await fixture.launcher.openSSHSetup(for: Self.host("saturno.example"))
        == .failed(.terminalWindow(.appNotRunning(appName: "Terminal"))))
    for each in [fixture, missing] {
      #expect(each.windows.sshSetupOpens.isEmpty && each.windows.opens.isEmpty)
      #expect(try Self.requestFiles(each.store).isEmpty)
    }
  } // End of func refusesBeforeWritingOrOpening()

  /// The real window layer opens with the helper's `ssh-setup` mode word, through the same
  /// steps as an attach: Terminal's D3 command text (`exec '<helper>' 'ssh-setup' '<token>'`)
  /// after the facts, the window recorded; an `exec` definition's argv carries the same word.
  /// Over the layer's fakes only.
  @Test func theWindowLayerOpensWithTheSSHSetupMode() throws {
    let terminal = try Self.terminal()
    let harness = PlainTerminalWindowsTests.harness(version: "2.15")
    let token = PlainTerminalWindowsTests.token
    harness.runner.queued[.open] = [
      .success(PlainTerminalWindowsTests.openReply("4711", "/dev/ttys004"))
    ]
    let window = try harness.windows.openSSHSetup(terminal, helperPath: Self.helper, token: token)
    #expect(
      window == PlainTerminalWindow(openedBy: terminal, windowID: "4711", tty: "/dev/ttys004"))
    #expect(
      harness.runner.calls.map(\.arguments) == [
        ["exec '\(Self.helper)' 'ssh-setup' '\(token.rawValue)'", "", "", ""]
      ])
    #expect(harness.windows.recordedWindows == [.init(openedBy: terminal, windowID: "4711")])
    #expect(harness.inspector.permissionReads == ["com.apple.Terminal"])

    let exec = try PlainTerminalWindowsTests.execDefinition()
    let execHarness = PlainTerminalWindowsTests.harness(version: "20250101", running: false)
    _ = try execHarness.windows.openSSHSetup(exec, helperPath: Self.helper, token: token)
    #expect(
      execHarness.spawner.requests.first?.arguments == [
        "start", "--always-new-process", "--", Self.helper, "ssh-setup", token.rawValue,
      ])
    let denied = PlainTerminalWindowsTests.harness(
      version: "2.15", status: AutomationPermission.deniedStatus)
    let refusal = PlainTerminalWindowsTests.failure { () throws(PlainTerminalWindowError) in
      try denied.windows.openSSHSetup(terminal, helperPath: Self.helper, token: token)
    }
    #expect(refusal == .permissionDenied(appName: "Terminal"))
    #expect(denied.runner.compiled.isEmpty && denied.runner.calls.isEmpty)
  } // End of func theWindowLayerOpensWithTheSSHSetupMode()
} // End of struct PlainSSHSetupLauncherTests

/// Cancels a task from the main actor (the task is set once it exists).
@MainActor
final class TaskCanceller {
  /// The task to cancel.
  var task: Task<SSHSetupResult, Never>?

  /// Cancels the task, if set.
  func cancel() {
    task?.cancel()
  }
}

/// A launch store that runs `afterWrite` right after each request it writes through `base`
/// (on the writer's thread), and counts the writes.
final class MainActorHoldingStore: SSHSetupRequestStore {
  /// The real store.
  private let base: LaunchStore
  /// Runs after each write.
  private let afterWrite: @Sendable () -> Void
  /// The writes so far.
  private let count = OSAllocatedUnfairLock(initialState: 0)

  /// A store over `base` running `afterWrite` after each write.
  init(base: LaunchStore, afterWrite: @escaping @Sendable () -> Void) {
    self.base = base
    self.afterWrite = afterWrite
  }

  /// How many requests were written.
  var writes: Int { count.withLock { $0 } }

  /// Writes through `base`, counts, then runs `afterWrite`.
  func writeRequest(_ request: SSHSetupRequest) throws(LaunchStoreError) {
    try base.writeRequest(request)
    count.withLock { $0 += 1 }
    afterWrite()
  }

  /// Withdraws through `base`.
  func discardRequest(_ id: LaunchToken) throws(LaunchStoreError) -> Bool {
    try base.discardRequest(id)
  }

  /// Sweeps through `base`.
  func sweep() throws(LaunchStoreError) -> Int {
    try base.sweep()
  }
} // End of class MainActorHoldingStore
