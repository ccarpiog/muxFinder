import Darwin
import Foundation
import Testing
import os

@testable import MuxFinderCore

/// `e2e-plain`'s arguments (PLAN.md D38 *The plain runs (I-12c3b)*): one terminal definition's
/// id (never `iterm2`), `--local` or `--ssh saturno-m4` only, the definition folders as
/// `terminals list` takes them, every option once; and the command owed to the user.
@Suite("e2e-plain: arguments")
struct E2EPlainOptionsTests {
  /// The options `arguments` parse to, or `nil`.
  static func options(_ arguments: [String]) -> E2EPlainOptions? {
    guard case .run(let options)? = try? E2EPlainOptions.parse(arguments) else { return nil }
    return options
  }

  /// The usage error `arguments` give, or `nil`.
  static func usageError(_ arguments: [String]) -> E2EPlainUsageError? {
    do throws(E2EPlainUsageError) {
      _ = try E2EPlainOptions.parse(arguments)
      return nil
    } catch {
      return error
    }
  }

  /// `--help` alone, a local and a remote run, and the definition folders.
  @Test func readsTheRuns() throws {
    for help in [["--help"], ["-h"], ["help"]] {
      #expect(try E2EPlainOptions.parse(help) == .help)
    }
    let local = try #require(Self.options(["--terminal", "terminal", "--local"]))
    #expect(local == E2EPlainOptions(terminalID: "terminal", target: .local))
    #expect(local.host.mode == .local)
    let remote = try #require(Self.options(["--ssh", "saturno-m4", "--terminal", "ghostty"]))
    #expect(remote.target == .ssh(destination: "saturno-m4"))
    #expect(remote.host.mode == .ssh && remote.host.sshDestination == "saturno-m4")
    let folders = try #require(
      Self.options([
        "--terminal", "terminal", "--local", "--builtin-directory", "/b", "--user-directory",
        "/u x",
      ]))
    #expect(folders.builtInDirectory == "/b" && folders.userDirectory == "/u x")
  } // End of func readsTheRuns()

  /// Every unusable combination is refused before anything is read or contacted: iTerm2 (it
  /// has its own runs), an invalid id, a host other than saturno-m4, both or neither of
  /// `--local` and `--ssh`, a missing terminal, an unknown option, an option twice or without
  /// its value, and `--help` with anything else.
  @Test func refusals() {
    let cases: [[String]] = [
      [],
      ["--local"],
      ["--terminal", "terminal"],
      ["--terminal", "iterm2", "--local"],
      ["--terminal", "Terminal!", "--local"],
      ["--terminal", "", "--local"],
      ["--terminal", "terminal", "--ssh", "sirio-m5"],
      ["--terminal", "terminal", "--ssh", "saturno-m4", "--local"],
      ["--terminal", "terminal", "--local", "--ssh", "saturno-m4"],
      ["--terminal", "terminal", "--local", "--local"],
      ["--terminal", "terminal", "--terminal", "ghostty", "--local"],
      ["--terminal", "terminal", "--local", "--builtin-directory"],
      ["--terminal", "terminal", "--local", "--frobnicate"],
      ["--terminal", "terminal", "--local", "--session", "$1"],
      ["--help", "--local"],
    ]
    for arguments in cases {
      #expect(Self.usageError(arguments) != nil, "\(arguments)")
    }
    #expect(Self.usageError(["--terminal", "iterm2", "--local"])?.message.contains("e2e-") == true)
    #expect(
      Self.usageError(["--terminal", "terminal", "--ssh", "x"])?.message.contains("saturno")
        == true)
  } // End of func refusals()

  /// The run's name and the exact command owed to the user, folders single-quoted.
  @Test func namesTheOwedCommand() throws {
    let local = E2EPlainOptions(terminalID: "terminal", target: .local)
    #expect(local.runName == "e2e-plain --terminal terminal --local")
    #expect(local.owedCommand == "swift run muxfinder-probe e2e-plain --terminal terminal --local")
    let remote = E2EPlainOptions(
      terminalID: "ghostty", target: .ssh(destination: "saturno-m4"), userDirectory: "/u x")
    #expect(remote.runName == "e2e-plain --terminal ghostty --ssh")
    #expect(
      remote.owedCommand
        == "swift run muxfinder-probe e2e-plain --terminal ghostty --ssh saturno-m4 "
        + "--user-directory '/u x'")
    let parsed = try #require(Self.options(["--terminal", "ghostty", "--ssh", "saturno-m4"]))
    #expect(Self.options(parsed.arguments) == parsed, "the arguments ask for the same run")
  } // End of func namesTheOwedCommand()

  /// An id no loaded definition has is refused with the load's counts; a loaded one is found.
  @Test func theDefinitionMustBeLoaded() throws {
    let catalog = TerminalDefinitionTestSupport.load(
      builtIn: TerminalDefinitionTestSupport.builtInDirectory)
    let found = try E2EPlainOptions(terminalID: "ghostty", target: .local).definition(in: catalog)
      .get()
    #expect(found.definition.id == "ghostty")
    let missing = E2EPlainOptions(terminalID: "kitty", target: .local).definition(in: catalog)
    guard case .failure(let refusal) = missing else {
      Issue.record("kitty was found")
      return
    }
    #expect(
      refusal == .unknownDefinition(id: "kitty", loaded: catalog.definitions.count, problems: 0))
    #expect(refusal.message.contains("kitty"))
  } // End of func theDefinitionMustBeLoaded()

  /// 0 only when every step passed and the steps finished; 1 for a failed step or a signal; 3
  /// for the watchdog; 2 is the gate's (and the probe's usage).
  @Test func exitStatuses() {
    let all = E2EPlainRun.stepCount
    #expect(E2EPlainRun.exitStatus(passed: all, ending: .finished) == 0)
    #expect(E2EPlainRun.exitStatus(passed: all - 1, ending: .finished) == 1)
    #expect(E2EPlainRun.exitStatus(passed: all, ending: .signal(SIGTERM)) == 1)
    #expect(E2EPlainRun.exitStatus(passed: 3, ending: .watchdog) == 3)
    #expect(E2EPlainRun.refusedStatus == 2)
  }
} // End of struct E2EPlainOptionsTests

/// Counting stand-ins for everything `e2e-plain` could contact, for the gate's and the close
/// order's tests: tmux that runs nothing, a control client starter that starts nothing, and
/// counting discovery.
final class E2EPlainContacts: Sendable {
  /// Counts.
  private struct State {
    /// tmux calls (versions included).
    var tmuxCalls = 0
    /// Control clients asked for.
    var starts = 0
  }

  /// The counts.
  private let state = OSAllocatedUnfairLock(initialState: State())
  /// Discovery, counting its calls.
  let discovery = FakeDiscovery(.ok([]))
  /// Every output line.
  let lines = OSAllocatedUnfairLock(initialState: [String]())

  /// tmux calls so far.
  var tmuxCalls: Int { state.withLock { $0.tmuxCalls } }
  /// Control clients asked for so far.
  var starts: Int { state.withLock { $0.starts } }

  /// tmux that counts each call and answers exit 1 with no output.
  struct Tmux: E2EPlainHostTmux {
    /// Where the counts go.
    let contacts: E2EPlainContacts

    /// `at a fake`.
    var location: String { "at a fake" }

    /// Counts the call; exit 1.
    func run(_ arguments: [String]) async throws -> E2EPlainTmuxOutput {
      contacts.state.withLock { $0.tmuxCalls += 1 }
      return E2EPlainTmuxOutput(status: 1, standardOutput: "", standardError: "", timedOut: false)
    }

    /// Counts the call; no version.
    func version() async -> String? {
      contacts.state.withLock { $0.tmuxCalls += 1 }
      return nil
    }

    /// A command nobody starts.
    func controlClientCommand(attachingTo name: String) -> E2EPlainProcessCommand {
      E2EPlainProcessCommand(executable: "/usr/bin/false", arguments: [], environment: [:])
    }
  } // End of struct Tmux

  /// A starter that counts and refuses.
  var starter: E2EPlainControlClientStarter {
    { [state] _ in
      state.withLock { $0.starts += 1 }
      throw ProcessRunnerError.spawnFailed(errno: EPERM)
    }
  }

  /// The parts of a run of `loaded` over these stand-ins (or `tmux`), `windows`, `inspector`,
  /// `store` and `processes` (by default a table where every pid is absent).
  @MainActor
  func parts(
    _ loaded: LoadedTerminalDefinition,
    windows: FakePlainTerminalWindowLayer,
    inspector: FakeTerminalAppInspector,
    store: LaunchStore,
    tmux: (any E2EPlainHostTmux)? = nil,
    processes: any E2EPlainHelperProcesses = FakeHelperProcesses(),
    budgets: E2EPlainRun.Budgets = E2EPlainRun.Budgets()
  ) -> E2EPlainRun.Parts {
    let options = E2EPlainOptions(terminalID: loaded.definition.id, target: .local)
    let lines = self.lines
    return E2EPlainRun.Parts(
      name: options.runName, owedCommand: options.owedCommand, loaded: loaded,
      host: options.host, tmux: tmux ?? Tmux(contacts: self), startControlClient: starter,
      windows: windows, inspector: inspector, helperPath: AttachTestSupport.helper, store: store,
      discovery: discovery, processStartTime: { _ in nil }, processes: processes,
      budgets: budgets, output: { line in lines.withLock { $0.append(line) } })
  } // End of func parts(_:windows:inspector:store:tmux:processes:budgets:)
} // End of class E2EPlainContacts

/// The kernel for `e2e-plain`'s cleanup tests: each pid's state as the test sets it (a pid not
/// set is absent), every SIGTERM the run asked for with the executable it named, and helpers
/// that end on one (their wait for Return finished). Nothing real is read or signalled.
final class FakeHelperProcesses: E2EPlainHelperProcesses, Sendable {
  /// One SIGTERM sent.
  struct Termination: Sendable, Hashable {
    /// The pid.
    let processID: Int32
    /// The executable the run named.
    let executable: String
  }

  /// The table.
  private struct State {
    /// Each pid's state.
    var states: [Int32: E2EPlainProcessState] = [:]
    /// The pids that end on a SIGTERM.
    var endsOnTerminate: Set<Int32> = []
    /// Every SIGTERM sent, in order.
    var terminations: [Termination] = []
  }

  /// The table's state.
  private let state = OSAllocatedUnfairLock(initialState: State())
  /// Runs at each SIGTERM sent, with its pid, before the process ends.
  let onTerminate = OSAllocatedUnfairLock<(@Sendable (Int32) -> Void)?>(initialState: nil)

  /// Makes `pid` read `newState` from now on; with `endsOnTerminate` a SIGTERM makes it absent.
  func set(_ pid: Int32, _ newState: E2EPlainProcessState, endsOnTerminate: Bool = false) {
    state.withLock { state in
      state.states[pid] = newState
      if endsOnTerminate {
        state.endsOnTerminate.insert(pid)
      } else {
        state.endsOnTerminate.remove(pid)
      }
    }
  } // End of func set(_:_:endsOnTerminate:)

  /// Every SIGTERM sent so far, in order.
  var terminations: [Termination] { state.withLock { $0.terminations } }

  /// The state set for `processID`, else `absent`.
  func state(of processID: Int32) -> E2EPlainProcessState {
    state.withLock { $0.states[processID] ?? .absent }
  }

  /// Sends (records) the SIGTERM only while `processID` reads running with `start`; then runs
  /// `onTerminate` and ends the process if it ends on one.
  func terminate(_ processID: Int32, startedAt start: ProcessStartTime, executable: String) -> Bool
  {
    let sent = state.withLock { state -> Bool in
      guard state.states[processID] == .running(start: start) else { return false }
      state.terminations.append(Termination(processID: processID, executable: executable))
      return true
    }
    guard sent else { return false }
    onTerminate.withLock { $0 }?(processID)
    state.withLock { state in
      if state.endsOnTerminate.contains(processID) { state.states[processID] = .absent }
    }
    return true
  } // End of func terminate(_:startedAt:executable:)
} // End of class FakeHelperProcesses

/// *Unattended-run rules* 8 comes first (PLAN.md D38 *The plain runs (I-12c3b)*): over fake
/// facts (the app not running, the permission denied, not determined, another status, the
/// target not running, and an `exec` definition's app not running) the run refuses with exit 2,
/// the reason and the owed command, and nothing is contacted: no tmux call (not even `-V`), no
/// session, no discovery, no control client, no request or other launch file, no window
/// opened, focused or closed, not even a run policy check.
@Suite("e2e-plain: the gate first")
@MainActor
struct E2EPlainGateTests {
  /// The built-in Terminal definition and an `exec` user definition.
  static func definitions() throws -> (
    terminal: LoadedTerminalDefinition, exec: LoadedTerminalDefinition
  ) {
    let exec = LoadedTerminalDefinition(
      definition: try TerminalDefinition.decode(
        TerminalDefinitionTestSupport.data(TerminalDefinitionTestSupport.execObject())),
      source: .user, fileName: "sample-exec.json", script: nil)
    return (try PlainBackendSupport.terminal(), exec)
  }

  /// An inspector answering an installed app of `version`, `running`, with `status`.
  static func inspector(
    version: String,
    running: Bool,
    status: Int32 = AutomationPermission.grantedStatus
  ) -> FakeTerminalAppInspector {
    FakeTerminalAppInspector(
      snapshot: TerminalAppSnapshot(
        url: URL(fileURLWithPath: "/Applications/Fixture.app"), version: version, running: running),
      status: status)
  }

  /// Each refusal, with nothing contacted.
  @Test func refusesWithNothingContacted() async throws {
    let (terminal, exec) = try Self.definitions()
    let cases: [(LoadedTerminalDefinition, FakeTerminalAppInspector, PlainRunGate.Refusal)] = [
      (terminal, Self.inspector(version: "2.14", running: false), .notRunning),
      (
        terminal, Self.inspector(version: "2.14", running: true, status: -1743),
        .permissionNotGranted(.denied)
      ),
      (
        terminal, Self.inspector(version: "2.14", running: true, status: -1744),
        .permissionNotGranted(.notDetermined)
      ),
      (
        terminal, Self.inspector(version: "2.14", running: true, status: -1),
        .permissionNotGranted(.other(status: -1))
      ),
      (
        terminal, Self.inspector(version: "2.14", running: true, status: -600),
        .permissionNotGranted(.targetNotRunning)
      ),
      (exec, Self.inspector(version: "20250101", running: false), .notRunning),
    ]
    for (loaded, inspector, expected) in cases {
      let root = try TestSupport.makeTemporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let store = LaunchStore(directory: root.appending(path: "launch"))
      let contacts = E2EPlainContacts()
      let windows = FakePlainTerminalWindowLayer()
      #expect(E2EPlainRun.gateRefusal(for: loaded, inspector: inspector) == expected)
      let run = E2EPlainRun(
        parts: contacts.parts(loaded, windows: windows, inspector: inspector, store: store))
      let status = await run.execute(limit: .seconds(10))
      #expect(status == 2, "\(expected.kind)")
      #expect(contacts.tmuxCalls == 0 && contacts.starts == 0 && contacts.discovery.calls == 0)
      #expect(windows.opens.isEmpty && windows.focuses.isEmpty && windows.closes.isEmpty)
      #expect(windows.runPolicyChecks == 0)
      #expect(!FileManager.default.fileExists(atPath: store.directory.path(percentEncoded: false)))
      #expect(await run.passedCount == 0)
      let lines = contacts.lines.withLock { $0 }
      #expect(lines.count == 2)
      #expect(lines.first?.contains(expected.message) == true)
      #expect(
        lines.last?.hasSuffix(
          "swift run muxfinder-probe e2e-plain --terminal \(loaded.definition.id) --local") == true)
    } // End of loop over the refusals
  } // End of func refusesWithNothingContacted()
} // End of struct E2EPlainGateTests

/// The cleanup order (PLAN.md D38 *The plain runs (I-12c3b)*): a window is closed only by the id
/// the layer's own open recorded, and only once its helper's process has ended: while the
/// helper runs nothing is closed (the window is left open after the wait); a helper with
/// neither a report nor a result is unknown, so its window is left open too (a result naming
/// it, its process gone, lets it close); a window the terminal already closed (-1728) is left
/// as it is; the gate's recheck refusing the close leaves it and is noted.
@Suite("e2e-plain: closes after the process ended")
@MainActor
struct E2EPlainCloseOrderTests {
  /// The fake helpers' values.
  enum Helper {
    /// The fake helper's pid.
    static let pid: Int32 = 4711
    /// Its start time while it runs.
    static let start = ProcessStartTime(seconds: 1_792_600_000, microseconds: 1)
    /// Its attach child's start time, as its early report names it (after the helper's).
    static let childStart = ProcessStartTime(seconds: 1_792_600_000, microseconds: 2)
  }

  /// Short waits: 300 ms for a helper's end, 1.5 s of SIGTERMs, a look every 20 ms.
  static let budgets = E2EPlainRun.Budgets(
    helperEnd: .milliseconds(300), helperShutdown: .milliseconds(1500),
    pollInterval: .milliseconds(20))

  /// A run over the fake window layer, `processes` and `store`, with `budgets`.
  static func run(
    windows: FakePlainTerminalWindowLayer,
    processes: FakeHelperProcesses,
    store: LaunchStore,
    contacts: E2EPlainContacts
  ) throws -> E2EPlainRun {
    E2EPlainRun(
      parts: contacts.parts(
        try PlainBackendSupport.terminal(), windows: windows,
        inspector: E2EPlainGateTests.inspector(version: "2.14", running: true), store: store,
        processes: processes, budgets: budgets))
  }

  /// One open through the fake layer (registering its window there) and its update in the
  /// run's log; the helper's early report (naming `helperPID`) written when `reports`.
  static func open(
    _ windows: FakePlainTerminalWindowLayer,
    run: E2EPlainRun,
    store: LaunchStore,
    reports: Bool,
    helperPID: Int32 = Helper.pid
  ) async throws -> LaunchToken {
    let loaded = try PlainBackendSupport.terminal()
    let token = LaunchToken()
    let window = try windows.open(loaded, helperPath: "/x/muxfinder-launch", token: token)
    let log = await run.updates
    log.record(
      AttachUpdate(
        key: PlainBackendSupport.target().key, launchID: token,
        state: .plainLaunched(window: window), isCurrent: true))
    if reports {
      try store.writeReport(
        PlainLaunchReport(
          id: token, helperPID: helperPID, terminalPath: "/dev/ttys004", attachChildPID: 9001,
          attachChildStartTime: Helper.childStart))
    }
    return token
  } // End of static func open(_:run:store:reports:helperPID:)

  /// While the helper runs nothing is closed; once it ended the window is closed by its id;
  /// a window with no known helper is never closed; one already gone is left as it is.
  @Test func closesOnlyAfterTheHelperEnded() async throws {
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    let windows = FakePlainTerminalWindowLayer()
    let processes = FakeHelperProcesses()
    processes.set(Helper.pid, .running(start: Helper.start))
    let run = try Self.run(
      windows: windows, processes: processes, store: store, contacts: E2EPlainContacts())
    let first = try await Self.open(windows, run: run, store: store, reports: true)
    windows.onClose = { _ throws(PlainTerminalWindowError) in
      if processes.state(of: Helper.pid) != .absent { Issue.record("closed while its helper ran") }
    }
    #expect(await run.closeWindow(of: first) == .helperStillRuns)
    #expect(windows.closes.isEmpty, "nothing closed while the helper runs")
    processes.set(Helper.pid, .absent)
    #expect(await run.closeWindow(of: first) == .closed)
    #expect(windows.closed.map(\.windowID) == ["fake-window-1"])
    #expect(await run.closeWindow(of: first) == .closedBefore, "closed once")
    // No report, so the helper is unknown: never closed.
    let second = try await Self.open(windows, run: run, store: store, reports: false)
    #expect(await run.closeWindow(of: second) == .helperUnknown)
    #expect(windows.closes.count == 1)
    // Its result names its helper (no longer running): closed then.
    try store.writeResult(PlainBackendSupport.result(for: second))
    #expect(await run.closeWindow(of: second) == .closed)
    #expect(windows.closed.count == 2)
    // Gone already (the terminal's own settings): left as it is.
    let third = try await Self.open(windows, run: run, store: store, reports: true)
    windows.closeFailure = .windowGone(appName: "Terminal")
    #expect(await run.closeWindow(of: third) == .alreadyGone)
    #expect(windows.closed.count == 2)
    // The gate's recheck refusing the close leaves the window and is noted.
    windows.closeFailure = nil
    let fourth = try await Self.open(windows, run: run, store: store, reports: true)
    windows.closeFailure = .unattendedRunRefused(appName: "Terminal", .notRunning)
    let refused = await run.closeWindow(of: fourth)
    #expect(refused == .refused(.unattendedRunRefused(appName: "Terminal", .notRunning)))
    #expect(!refused.passes)
    #expect(await run.gateRefusal == .notRunning)
  } // End of func closesOnlyAfterTheHelperEnded()
} // End of struct E2EPlainCloseOrderTests

/// No close without positive evidence (PLAN.md D38 *The plain runs (I-12c3b)*, review B1): a
/// kernel answer that could not be read is never taken for an ended helper, neither at the first
/// look (no start time recorded yet) nor later; nor is a pid whose process started after the
/// helper's own early report. Only an absent pid, or the pid with another start time than the
/// one recorded, lets the window close.
@Suite("e2e-plain: an unreadable process is not an ended one")
@MainActor
struct E2EPlainUnreadableProcessTests {
  /// Shorthand.
  typealias Helper = E2EPlainCloseOrderTests.Helper

  /// The report's helper read unreadable, then running, then unreadable again: its window stays
  /// open throughout; once its pid shows another start time it is closed.
  @Test func anUnreadableHelperKeepsItsWindowOpen() async throws {
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    let windows = FakePlainTerminalWindowLayer()
    let processes = FakeHelperProcesses()
    let run = try E2EPlainCloseOrderTests.run(
      windows: windows, processes: processes, store: store, contacts: E2EPlainContacts())
    windows.onClose = { _ throws(PlainTerminalWindowError) in
      let now = processes.state(of: Helper.pid)
      if now == .unreadable || now == .running(start: Helper.start) {
        Issue.record("closed without evidence that its helper ended")
      }
    }
    processes.set(Helper.pid, .unreadable)
    let token = try await E2EPlainCloseOrderTests.open(
      windows, run: run, store: store, reports: true)
    #expect(await run.closeWindow(of: token) == .helperUnreadable, "the first look")
    processes.set(Helper.pid, .running(start: Helper.start))
    #expect(await run.closeWindow(of: token) == .helperStillRuns)
    processes.set(Helper.pid, .unreadable)
    #expect(await run.closeWindow(of: token) == .helperUnreadable, "after its start was recorded")
    #expect(windows.closes.isEmpty)
    let other = ProcessStartTime(seconds: 1_792_600_500, microseconds: 0)
    processes.set(Helper.pid, .running(start: other))
    #expect(await run.closeWindow(of: token) == .closed, "its pid now names another process")
    #expect(windows.closed.count == 1)
  } // End of func anUnreadableHelperKeepsItsWindowOpen()

  /// A pid whose process started after the report's attach child cannot be the helper, nor is
  /// it evidence that the helper ended: the window is left; once the pid is absent it closes.
  @Test func aProcessStartedAfterTheReportIsNotTakenForTheHelper() async throws {
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    let windows = FakePlainTerminalWindowLayer()
    let processes = FakeHelperProcesses()
    let run = try E2EPlainCloseOrderTests.run(
      windows: windows, processes: processes, store: store, contacts: E2EPlainContacts())
    let later = ProcessStartTime(seconds: 1_792_600_300, microseconds: 0)
    processes.set(Helper.pid, .running(start: later))
    let token = try await E2EPlainCloseOrderTests.open(
      windows, run: run, store: store, reports: true)
    #expect(await run.closeWindow(of: token) == .helperUnreadable)
    #expect(windows.closes.isEmpty)
    processes.set(Helper.pid, .absent)
    #expect(await run.closeWindow(of: token) == .closed)
  } // End of func aProcessStartedAfterTheReportIsNotTakenForTheHelper()
} // End of struct E2EPlainUnreadableProcessTests

/// Cleanup asks the run's own helpers that still run to stop (PLAN.md D38 *The plain runs
/// (I-12c3b)*, review S1): a helper that failed waits for Return in its window, so after the
/// session is gone cleanup sends it SIGTERM (only while its pid still has the start time it
/// was identified by, naming the run's helper executable), again while it runs, within
/// `helperShutdown`, and closes its window only once it ended. A helper that keeps running is
/// left and reported; one whose state cannot be read is never signalled.
@Suite("e2e-plain: cleanup stops its helpers")
@MainActor
struct E2EPlainHelperShutdownTests {
  /// Shorthand.
  typealias Helper = E2EPlainCloseOrderTests.Helper

  /// Three windows: a helper that ends on SIGTERM (asked, then its window closed), one that
  /// keeps running (asked again, left and reported), one that cannot be read (never asked).
  @Test func helpersThatStillRunAreAskedToStop() async throws {
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    let windows = FakePlainTerminalWindowLayer()
    let processes = FakeHelperProcesses()
    let contacts = E2EPlainContacts()
    let run = try E2EPlainCloseOrderTests.run(
      windows: windows, processes: processes, store: store, contacts: contacts)
    let (waiting, stubborn, unreadable): (Int32, Int32, Int32) = (4711, 4712, 4713)
    processes.set(waiting, .running(start: Helper.start), endsOnTerminate: true)
    processes.set(stubborn, .running(start: Helper.start))
    processes.set(unreadable, .unreadable)
    let first = try await E2EPlainCloseOrderTests.open(
      windows, run: run, store: store, reports: true, helperPID: waiting)
    let second = try await E2EPlainCloseOrderTests.open(
      windows, run: run, store: store, reports: true, helperPID: stubborn)
    let third = try await E2EPlainCloseOrderTests.open(
      windows, run: run, store: store, reports: true, helperPID: unreadable)
    windows.onClose = { window throws(PlainTerminalWindowError) in
      if window.windowID != "fake-window-1" || processes.state(of: waiting) != .absent {
        Issue.record("closed a window whose helper had not ended")
      }
    }
    await run.cleanUp()
    let signalled = processes.terminations
    #expect(signalled.filter { $0.processID == waiting }.count == 1)
    #expect(signalled.contains { $0.processID == stubborn })
    #expect(!signalled.contains { $0.processID == unreadable }, "never one not identified")
    #expect(signalled.allSatisfy { $0.executable == AttachTestSupport.helper.path })
    #expect(windows.closed.map(\.windowID) == ["fake-window-1"])
    let lines = contacts.lines.withLock { $0 }
    let cleanup = try #require(lines.first { $0.hasPrefix("FAIL 9 cleanup") })
    #expect(cleanup.contains("asked 2 helper(s) of the run's own that still ran to stop"))
    #expect(cleanup.contains("the window of launch \(first)") == false)
    #expect(cleanup.contains("the window of launch \(second) left open: its helper still runs"))
    #expect(
      cleanup.contains(
        "the window of launch \(third) left open: whether its helper still runs could not be read"))
    #expect(cleanup.contains("1 helper(s) of the run still running"))
    #expect(cleanup.contains("1 helper(s) of the run whose process could not be read"))
  } // End of func helpersThatStillRunAreAskedToStop()
} // End of struct E2EPlainHelperShutdownTests

/// Helpers are known by launch token, whatever became of their window (PLAN.md D38 *The plain
/// runs (I-12c3b)*, review S2): an open that returned an error after its Apple event (the
/// script may have opened the window and started the helper first) published no window, yet its
/// helper, named by its early report, is recorded before any launch file is removed, asked to
/// stop and seen ended before its report goes; and the launch is reported, since its window has
/// no recorded id. An open that failed after its Apple event with no helper file is reported
/// too; one refused before anything was sent is not.
@Suite("e2e-plain: helpers by launch token")
@MainActor
struct E2EPlainHelpersByTokenTests {
  /// Shorthand.
  typealias Helper = E2EPlainCloseOrderTests.Helper

  /// Records `failure` as `launchID`'s end in `run`'s log, after a `requested` update.
  static func failed(_ launchID: LaunchToken, _ failure: AttachFailure, in run: E2EPlainRun) async {
    let log = await run.updates
    let key = PlainBackendSupport.target().key
    log.record(AttachUpdate(key: key, launchID: launchID, state: .requested, isCurrent: true))
    log.record(
      AttachUpdate(key: key, launchID: launchID, state: .failed(failure), isCurrent: true))
  }

  /// The three failed opens, through the whole cleanup.
  @Test func aFailedOpenKeepsItsHelperTracked() async throws {
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    let windows = FakePlainTerminalWindowLayer()
    let processes = FakeHelperProcesses()
    let contacts = E2EPlainContacts()
    let run = try E2EPlainCloseOrderTests.run(
      windows: windows, processes: processes, store: store, contacts: contacts)
    let started = LaunchToken()
    await Self.failed(
      started, .terminalWindow(.malformedReply(appName: "Terminal", handler: .open)), in: run)
    try store.writeReport(
      PlainLaunchReport(
        id: started, helperPID: Helper.pid, terminalPath: "/dev/ttys004", attachChildPID: 9001,
        attachChildStartTime: Helper.childStart))
    processes.set(Helper.pid, .running(start: Helper.start), endsOnTerminate: true)
    let uncertain = LaunchToken()
    await Self.failed(
      uncertain,
      .terminalWindow(
        .scriptFailed(appName: "Terminal", .callFailed(handler: .open, errorNumber: -1712))),
      in: run)
    let refused = LaunchToken()
    await Self.failed(
      refused, .terminalWindow(.unattendedRunRefused(appName: "Terminal", .notRunning)), in: run)
    let report = store.directory.appending(path: LaunchStore.reportFileName(for: started))
      .path(percentEncoded: false)
    let reportAtSignal = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    processes.onTerminate.withLock {
      $0 = { _ in reportAtSignal.withLock { $0 = FileManager.default.fileExists(atPath: report) } }
    }
    await run.cleanUp()
    #expect(
      processes.terminations == [
        .init(processID: Helper.pid, executable: AttachTestSupport.helper.path)
      ])
    #expect(reportAtSignal.withLock { $0 } == true, "its report kept until it ended")
    #expect(!FileManager.default.fileExists(atPath: report), "removed once it ended")
    #expect(windows.closes.isEmpty)
    let lines = contacts.lines.withLock { $0 }
    let cleanup = try #require(lines.first { $0.hasPrefix("FAIL 9 cleanup") })
    #expect(cleanup.contains("asked 1 helper(s) of the run's own that still ran to stop"))
    #expect(cleanup.contains("launch \(started) recorded no window although a helper ran for it"))
    #expect(
      cleanup.contains(
        "launch \(uncertain) recorded no window although its open failed (scriptFailed) after "
          + "the Apple event was sent"))
    #expect(!cleanup.contains("\(refused)"))
    #expect(!cleanup.contains("still running") && !cleanup.contains("launch file"))
    #expect(lines.filter { $0.hasPrefix("  look for a Terminal window of launch ") }.count == 2)
  } // End of func aFailedOpenKeepsItsHelperTracked()
} // End of struct E2EPlainHelpersByTokenTests

/// tmux for `e2e-plain`'s session check: `tmux -V` answers, `new-session` loses its reply (as
/// over ssh when the connection drops after the session was made), `list-sessions` answers
/// `listing`, every other call exits 1. Records the subcommands it was asked for.
struct LostReplyTmux: E2EPlainHostTmux {
  /// What every `list-sessions` answers.
  let listing: E2EPlainTmuxOutput
  /// The subcommands asked for, in order.
  let calls = OSAllocatedUnfairLock(initialState: [String]())

  /// `on a fake`.
  var location: String { "on a fake" }

  /// Answers by subcommand, as above.
  func run(_ arguments: [String]) async throws -> E2EPlainTmuxOutput {
    calls.withLock { $0.append(arguments.first ?? "") }
    switch arguments.first {
    case "new-session":
      return E2EPlainTmuxOutput(status: nil, standardOutput: "", standardError: "", timedOut: true)
    case "list-sessions":
      return listing
    default:
      return E2EPlainTmuxOutput(status: 1, standardOutput: "", standardError: "", timedOut: false)
    }
  } // End of func run(_:)

  /// `tmux 3.8`.
  func version() async -> String? { "tmux 3.8" }

  /// A command nobody starts.
  func controlClientCommand(attachingTo name: String) -> E2EPlainProcessCommand {
    E2EPlainProcessCommand(executable: "/usr/bin/false", arguments: [], environment: [:])
  }
} // End of struct LostReplyTmux

/// A session whose absence cannot be established fails cleanup (PLAN.md D38 *The plain runs
/// (I-12c3b)*, review S3): step 1's `new-session` lost its reply, so the session may exist; when
/// `list-sessions` also fails (ssh unreachable, tmux's own error, a timeout) cleanup cannot show
/// it is gone and fails, saying so; tmux's "no server running" answer and a listing without it
/// are genuine absences, and cleanup passes.
@Suite("e2e-plain: the session's absence must be established")
@MainActor
struct E2EPlainSessionAbsenceTests {
  /// Runs the whole run over `LostReplyTmux` answering `listing`; returns its status, its
  /// output and the subcommands tmux was asked for.
  static func run(listing: E2EPlainTmuxOutput) async throws -> (Int32, [String], [String]) {
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    let contacts = E2EPlainContacts()
    let tmux = LostReplyTmux(listing: listing)
    let run = E2EPlainRun(
      parts: contacts.parts(
        try PlainBackendSupport.terminal(), windows: FakePlainTerminalWindowLayer(),
        inspector: E2EPlainGateTests.inspector(version: "2.14", running: true), store: store,
        tmux: tmux, budgets: E2EPlainCloseOrderTests.budgets))
    let status = await run.execute(limit: .seconds(10))
    return (status, contacts.lines.withLock { $0 }, tmux.calls.withLock { $0 })
  } // End of static func run(listing:)

  /// A listing that fails: cleanup fails, naming why, with what to check by hand.
  @Test func aFailedListingIsNotAnAbsence() async throws {
    let failures = [
      E2EPlainTmuxOutput(
        status: 255, standardOutput: "",
        standardError: "ssh: connect to host saturno-m4 port 22: Operation timed out\n",
        timedOut: false),
      E2EPlainTmuxOutput(
        status: 1, standardOutput: "", standardError: "server exited unexpectedly\n",
        timedOut: false),
      E2EPlainTmuxOutput(status: nil, standardOutput: "", standardError: "", timedOut: true),
    ]
    for listing in failures {
      let (status, lines, calls) = try await Self.run(listing: listing)
      let output = lines.joined(separator: "\n")
      #expect(status == 1, "\(output)")
      #expect(lines.contains { $0.hasPrefix("FAIL 1 create session") }, "\(output)")
      #expect(!lines.contains { $0.hasPrefix("PASS 9 cleanup") }, "\(output)")
      let cleanup = try #require(lines.first { $0.hasPrefix("FAIL 9 cleanup") }, "\(output)")
      #expect(cleanup.contains("whether the test session is gone could not be established"))
      #expect(lines.contains { $0.hasPrefix("  look for the session muxfinder-test-") })
      #expect(calls.filter { $0 == "list-sessions" }.count == 3, "step 1, the kill, the check")
      #expect(!calls.contains("if-shell") && !calls.contains("kill-session"))
    } // End of loop over the failed listings
  } // End of func aFailedListingIsNotAnAbsence()

  /// "No server running" and a listing without the session: cleanup passes.
  @Test func aGenuineAbsencePasses() async throws {
    let absences = [
      E2EPlainTmuxOutput(
        status: 1, standardOutput: "",
        standardError: "no server running on /private/tmp/tmux-501/default\n", timedOut: false),
      E2EPlainTmuxOutput(
        status: 1, standardOutput: "",
        standardError: "error connecting to /tmp/tmux-501/default (No such file or directory)\n",
        timedOut: false),
      E2EPlainTmuxOutput(
        status: 0, standardOutput: "another-session\n", standardError: "", timedOut: false),
    ]
    for listing in absences {
      let (status, lines, _) = try await Self.run(listing: listing)
      let output = lines.joined(separator: "\n")
      #expect(status == 1, "\(output)")
      #expect(lines.contains { $0.hasPrefix("PASS 9 cleanup") }, "\(output)")
    } // End of loop over the absences
  } // End of func aGenuineAbsencePasses()
} // End of struct E2EPlainSessionAbsenceTests

/// The real kernel reading and stop (`E2EPlainKernelProcesses`), on a `/bin/sleep` child of the
/// test's own, the only process signalled: its state reads `running` with the kernel's start
/// time; SIGTERM is refused for another start time or another executable, then sent for its
/// own; once it is reaped its pid reads `absent`. A pid below 1 reads `unreadable` and is never
/// signalled.
@Suite("e2e-plain: the kernel's processes (real, a child of the test's)")
struct E2EPlainKernelProcessesTests {
  /// See the suite.
  @Test(.timeLimit(.minutes(1)))
  func readsAndStopsOnlyTheIdentifiedProcess() async throws {
    let kernel = E2EPlainKernelProcesses()
    #expect(kernel.state(of: 0) == .unreadable && kernel.state(of: -1) == .unreadable)
    let anyStart = ProcessStartTime(seconds: 1, microseconds: 0)
    #expect(!kernel.terminate(0, startedAt: anyStart, executable: "/bin/sleep"))
    #expect(!kernel.terminate(-1, startedAt: anyStart, executable: "/bin/sleep"))
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try child.run()
    defer { if child.isRunning { child.terminate() } }
    let pid = child.processIdentifier
    guard case .running(let start) = kernel.state(of: pid) else {
      Issue.record("the child does not read running")
      return
    }
    #expect(ProcessStartTime.of(pid) == start)
    let earlier = ProcessStartTime(seconds: start.seconds - 1, microseconds: start.microseconds)
    #expect(!kernel.terminate(pid, startedAt: earlier, executable: "/bin/sleep"))
    #expect(!kernel.terminate(pid, startedAt: start, executable: "/bin/cat"))
    #expect(child.isRunning, "nothing was sent")
    #expect(kernel.terminate(pid, startedAt: start, executable: "/bin/sleep"))
    let deadline = ContinuousClock.now + .seconds(10)
    while child.isRunning, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!child.isRunning)
    #expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGTERM)
    #expect(kernel.state(of: pid) == .absent)
  } // End of func readsAndStopsOnlyTheIdentifiedProcess()
} // End of struct E2EPlainKernelProcessesTests
