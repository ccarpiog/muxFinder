import AppKit
import Darwin
import Foundation
import Testing
import os

@testable import MuxFinderCore

/// The plain window layer's seams and failures (PLAN.md D38, Phase I-12b3): the real spawner on
/// `/bin/sleep` (detached, never waited for, never ended, reaped once it exits), its refusals,
/// the real activator for an app that does not exist (nothing launched), the fakes, and every
/// failure's kind and sentence. No terminal app, no Apple event, no iTerm2.
@Suite("Plain terminal seams")
struct PlainTerminalSeamsTests {
  /// Whether `processID` is still unreaped (alive or a zombie), without reaping it.
  static func isUnreaped(_ processID: pid_t) -> Bool {
    var info = siginfo_t()
    while true {
      if waitid(P_PID, id_t(processID), &info, WEXITED | WNOHANG | WNOWAIT) == 0 { return true }
      if errno != EINTR { return false }
    }
  }

  /// The real spawner returns while its program runs, puts it in a session of its own (so its
  /// own process group, no controlling terminal), never ends it when the call returns, and
  /// reaps it once it exits.
  @Test func realSpawnerDetachesAndReaps() async throws {
    let start = ContinuousClock.now
    let processID = try DetachedTerminalProcessSpawner().spawn(
      TerminalSpawnRequest(
        executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:]))
    #expect(ContinuousClock.now - start < .seconds(5))
    #expect(processID > 0)
    try await Task.sleep(for: .milliseconds(200))
    #expect(kill(processID, 0) == 0, "still running after the call returned")
    #expect(getsid(processID) == processID, "a session of its own")
    #expect(getpgid(processID) == processID, "its own process group")
    #expect(getsid(processID) != getsid(0))
    #expect(kill(processID, SIGKILL) == 0)
    let deadline = ContinuousClock.now + .seconds(5)
    while Self.isUnreaped(processID), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!Self.isUnreaped(processID), "reaped by the reaper, never left a zombie")
  } // End of func realSpawnerDetachesAndReaps()

  /// A program that exits at once is reaped too (also when it ended before the watch began).
  @Test func realSpawnerReapsAQuickExit() async throws {
    let processID = try DetachedTerminalProcessSpawner().spawn(
      TerminalSpawnRequest(
        executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], environment: [:]))
    let deadline = ContinuousClock.now + .seconds(5)
    while Self.isUnreaped(processID), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!Self.isUnreaped(processID))
  }

  /// A wait seam for the reaper: it answers the scripted answers first (without asking the
  /// kernel), then waits for real (`DetachedChildReaper.waitWithoutBlocking`), and counts every
  /// call.
  final class ScriptedWait: Sendable {
    /// The answers still to give, and how many waits were asked for.
    private let state: OSAllocatedUnfairLock<(script: [DetachedChildReaper.WaitAnswer], calls: Int)>

    /// A wait answering `script` first.
    init(_ script: [DetachedChildReaper.WaitAnswer]) {
      state = OSAllocatedUnfairLock(initialState: (script, 0))
    }

    /// The next scripted answer, else a real nonblocking wait for `processID`.
    func callAsFunction(_ processID: pid_t) -> DetachedChildReaper.WaitAnswer {
      let scripted = state.withLock { state -> DetachedChildReaper.WaitAnswer? in
        state.calls += 1
        return state.script.isEmpty ? nil : state.script.removeFirst()
      }
      return scripted ?? DetachedChildReaper.waitWithoutBlocking(processID)
    }

    /// How many waits were asked for.
    var calls: Int { state.withLock { $0.calls } }
  } // End of class ScriptedWait

  /// Spawns `/usr/bin/true` (it exits at once) through a spawner whose reaper waits with
  /// `wait`, and returns its pid once the reaper's watch of it ended (or 5 s passed), whether
  /// it was then still unreaped, and the reaper. Reaps it itself when the reaper dropped it
  /// unreaped, so no zombie stays behind either way.
  static func spawnTrue(
    waitingWith wait: ScriptedWait
  ) async throws -> (processID: pid_t, leftUnreaped: Bool, reaper: DetachedChildReaper) {
    let reaper = DetachedChildReaper { wait($0) }
    let processID = try DetachedTerminalProcessSpawner(reaper: reaper).spawn(
      TerminalSpawnRequest(
        executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], environment: [:]))
    let deadline = ContinuousClock.now + .seconds(5)
    while reaper.watchedCount > 0, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let leftUnreaped = isUnreaped(processID)
    if leftUnreaped, reaper.watchedCount == 0 {
      var status: Int32 = 0
      while waitpid(processID, &status, 0) == -1, errno == EINTR {}
    }
    return (processID, leftUnreaped, reaper)
  } // End of static func spawnTrue(waitingWith:)

  /// The exit can be seen before the child can be waited for (XNU posts `NOTE_EXIT` before it
  /// makes the process a zombie), so the first nonblocking waits may answer 0 (review finding
  /// 3). Forced through the wait seam, since the real race cannot be forced: two answers of 0
  /// with an `EINTR` between them, then real waits. The reaper keeps the child pending, waits
  /// again (at once after `EINTR`, after a growing pause after 0) and reaps it, and only then
  /// drops its watch.
  @Test func reaperKeepsWaitingWhenTheExitComesFirst() async throws {
    let notYet = DetachedChildReaper.WaitAnswer(result: 0, error: 0)
    let interrupted = DetachedChildReaper.WaitAnswer(result: -1, error: EINTR)
    let wait = ScriptedWait([notYet, interrupted, notYet])
    let run = try await Self.spawnTrue(waitingWith: wait)
    #expect(!run.leftUnreaped, "reaped by the reaper after the early answers")
    #expect(run.reaper.watchedCount == 0)
    #expect(wait.calls >= 4)
    #expect(
      (1...13).map { DetachedChildReaper.retryDelayMilliseconds(afterNotYet: $0) } == [
        1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1000, 1000, 1000,
      ])
  } // End of func reaperKeepsWaitingWhenTheExitComesFirst()

  /// A wait that answers `ECHILD` (nothing left to reap) ends the watch without another wait:
  /// the reaper never loops on a child it cannot reap. The scripted answer never asked the
  /// kernel, so the child is left unreaped, and the test reaps it itself.
  @Test func reaperStopsAtNoSuchChild() async throws {
    let wait = ScriptedWait([DetachedChildReaper.WaitAnswer(result: -1, error: ECHILD)])
    let run = try await Self.spawnTrue(waitingWith: wait)
    #expect(run.reaper.watchedCount == 0)
    #expect(wait.calls == 1)
    #expect(run.leftUnreaped)
    #expect(!Self.isUnreaped(run.processID), "reaped by the test")
  }

  /// A missing executable, a URL that is not a file path and a NUL in an argument are typed
  /// failures; nothing runs.
  @Test func realSpawnerRefusals() throws {
    let spawner = DetachedTerminalProcessSpawner()
    /// The failure of spawning `request`.
    func failure(_ request: TerminalSpawnRequest) -> ProcessRunnerError? {
      do throws(ProcessRunnerError) {
        _ = try spawner.spawn(request)
        return nil
      } catch {
        return error
      }
    }
    let missing = URL(fileURLWithPath: "/private/tmp/muxfinder-no-such-\(UUID().uuidString)/x")
    #expect(
      failure(TerminalSpawnRequest(executable: missing, arguments: [], environment: [:]))
        == .spawnFailed(errno: ENOENT))
    let web = try #require(URL(string: "https://example.com/terminal"))
    #expect(
      failure(TerminalSpawnRequest(executable: web, arguments: [], environment: [:]))
        == .executableNotAbsolute)
    #expect(
      failure(
        TerminalSpawnRequest(
          executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: ["a\u{0}b"],
          environment: [:])) == .argumentContainsNUL(index: 0))
  } // End of func realSpawnerRefusals()

  /// The real activator finds no running app for an identifier nobody uses and launches
  /// nothing.
  @Test @MainActor func realActivatorNeverLaunches() {
    let identifier = "test.muxfinder.no-such-terminal-app"
    #expect(RunningApplicationActivator().activate(bundleIdentifier: identifier) == .notRunning)
    #expect(NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty)
  }

  /// The fakes record what they were asked and answer what the test set.
  @Test @MainActor func fakesRecordAndAnswer() throws {
    let snapshot = TerminalAppSnapshot(url: nil, version: nil, running: false)
    let inspector = FakeTerminalAppInspector(snapshot: snapshot, status: -1744)
    #expect(inspector.snapshot(bundleIdentifier: "a.b") == snapshot)
    #expect(inspector.automationStatus(bundleIdentifier: "c.d") == -1744)
    #expect(inspector.snapshotReads == ["a.b"] && inspector.permissionReads == ["c.d"])
    let spawner = FakeTerminalProcessSpawner()
    let request = TerminalSpawnRequest(
      executable: URL(fileURLWithPath: "/x"), arguments: ["y"], environment: ["Z": "1"])
    #expect(try spawner.spawn(request) == FakeTerminalProcessSpawner.firstProcessID)
    #expect(try spawner.spawn(request) == FakeTerminalProcessSpawner.firstProcessID + 1)
    spawner.setFailure(.spawnFailed(errno: EACCES))
    #expect(throws: ProcessRunnerError.spawnFailed(errno: EACCES)) { try spawner.spawn(request) }
    #expect(spawner.requests == [request, request, request])
    let activator = FakeTerminalAppActivator(answer: .refused)
    #expect(activator.activate(bundleIdentifier: "e.f") == .refused)
    #expect(activator.requests == ["e.f"])
  } // End of func fakesRecordAndAnswer()

  /// Every failure's kind and plain sentence (sentence case, no path or command), and
  /// `localizedDescription`.
  @Test func everyFailureHasItsSentence() {
    let cases: [(PlainTerminalWindowError, String, String)] = [
      (
        .appNotInstalled(appName: "Ghostty"), "appNotInstalled",
        "muxFinder can't find Ghostty on this Mac. Install it, or choose another terminal."
      ),
      (
        .appTooOld(appName: "Ghostty", installed: "1.2.9", minimum: "1.3"), "appTooOld",
        "Ghostty 1.2.9 is too old for muxFinder. Update it to 1.3 or later."
      ),
      (
        .appVersionUnknown(appName: "Ghostty", minimum: "1.3"), "appVersionUnknown",
        "muxFinder can't tell which version of Ghostty is installed, and it needs 1.3 or "
          + "later. Update Ghostty and try again."
      ),
      (
        .permissionDenied(appName: "Terminal"), "permissionDenied",
        "muxFinder isn't allowed to control Terminal. Turn it on in System Settings › Privacy "
          + "& Security › Automation, then try again."
      ),
      (
        .appNotRunning(appName: "Terminal"), "appNotRunning",
        "Terminal isn't running, so the session's window is gone."
      ),
      (
        .activationFailed(appName: "Terminal"), "activationFailed",
        "macOS didn't bring Terminal to the front. Switch to it to find the session's window."
      ),
      (
        .launchCommandRefused(.helperPathUnsafeForWords), "launchCommandRefused",
        TerminalLaunchCommandError.helperPathUnsafeForWords.message
      ),
      (
        .scriptFailed(appName: "Ghostty", .compileFailed(errorNumber: -2741)), "scriptFailed",
        "muxFinder couldn't load its script for Ghostty (error -2741)."
      ),
      (
        .scriptFailed(appName: "Ghostty", .callFailed(handler: .open, errorNumber: -1708)),
        "scriptFailed", "Ghostty couldn't open a window (error -1708)."
      ),
      (
        .scriptFailed(appName: "Ghostty", .callFailed(handler: .focus, errorNumber: -10004)),
        "scriptFailed", "Ghostty couldn't bring the window forward (error -10004)."
      ),
      (
        .scriptFailed(appName: "Ghostty", .wrongArgumentCount(handler: .close)), "scriptFailed",
        "Ghostty couldn't close the window."
      ),
      (
        .scriptMissing(appName: "Terminal"), "scriptMissing",
        "muxFinder's definition for Terminal has no script, so it can't open windows there."
      ),
      (
        .malformedReply(appName: "Terminal", handler: .open), "malformedReply",
        "Terminal answered muxFinder in a way it doesn't understand, so muxFinder stopped."
      ),
      (
        .spawnFailed(appName: "WezTerm", .spawnFailed(errno: ENOENT)), "spawnFailed",
        "muxFinder couldn't start WezTerm (No such file or directory)."
      ),
      (
        .spawnFailed(appName: "WezTerm", .argumentContainsNUL(index: 2)), "spawnFailed",
        "muxFinder couldn't start WezTerm."
      ),
      (
        .windowOfAnotherTerminal, "windowOfAnotherTerminal",
        "This window belongs to another terminal, so muxFinder left it alone."
      ),
      (
        .definitionChanged(appName: "Terminal"), "definitionChanged",
        "muxFinder's definition for Terminal changed after it opened this window, so "
          + "muxFinder left the window alone."
      ),
      (
        .notOpenedHere, "notOpenedHere",
        "muxFinder didn't open this window, so it won't close it."
      ),
      (
        .windowLacksFocusValue(appName: "Terminal", .tty), "windowLacksFocusValue",
        "Terminal didn't report its terminal device for this window, so muxFinder can't bring "
          + "it forward. Switch to Terminal to find it."
      ),
      (
        .windowLacksFocusValue(appName: "Ghostty", .windowID), "windowLacksFocusValue",
        "Ghostty didn't report an id for this window, so muxFinder can't bring it forward. "
          + "Switch to Ghostty to find it."
      ),
      (
        .windowHasNoID(appName: "Terminal"), "windowHasNoID",
        "Terminal didn't report an id for this window, so muxFinder can't close it. Close it "
          + "in Terminal."
      ),
      (
        .windowBusy(appName: "Terminal"), "windowBusy",
        "The Terminal window is still running something, so muxFinder left it open."
      ),
      (
        .windowGone(appName: "Ghostty"), "windowGone",
        "The Ghostty window is already closed."
      ),
    ]
    for (error, kind, message) in cases {
      #expect(error.kind == kind)
      #expect(error.message == message)
      #expect(error.localizedDescription == message)
      let startsAsASentence =
        message.first?.isUppercase == true || message.hasPrefix("muxFinder")
        || message.hasPrefix("macOS")
      #expect(startsAsASentence)
      #expect(message.hasSuffix("."))
    } // End of loop over every failure
    #expect(Set(cases.map(\.1)).count == 18, "every case is covered")
  } // End of func everyFailureHasItsSentence()
} // End of struct PlainTerminalSeamsTests
