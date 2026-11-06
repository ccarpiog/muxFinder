import Foundation

/// `muxfinder-probe e2e-plain --terminal <id> --local | --ssh saturno-m4`: the real run of the
/// plain backend in one terminal app other than iTerm2 (PLAN.md D38 *The plain runs
/// (I-12c3b)*). It lives in the core so its gate, its steps and its cleanup are tested
/// hermetically over fakes and a private tmux server; the probe passes the real parts
/// (`PlainTerminalWindows` with the `unattended` run policy over the real `NSAppleScript`
/// runner, the launch helper, the real launch store, discovery, the host's tmux locally or over
/// BatchMode ssh, This Mac's client attributor).
///
/// **The gate first** (*Unattended-run rules* 8): before anything is created, written,
/// discovered or sent, the app's facts are read with nothing sent (`TerminalAppFacts`) and
/// `PlainRunGate` must let the run go ahead (the app running and, for an AppleScript
/// definition, its permission reading granted without a prompt); otherwise `execute(limit:
/// interrupts:)` prints the reason and the command owed to the user and returns 2. During the
/// run the window layer's own policy checks the gate again right before every open, focus and
/// close; a refusal there fails the step (exit 1) and cleanup undoes what the run made.
///
/// Steps (each prints one PASS or FAIL line; the first failure stops the run, then cleanup
/// runs):
/// 1. **create session:** `muxfinder-test-<hex>` with one window running `sleep 600`, on the
///    host's default tmux server (remotely over BatchMode ssh).
/// 2. **discover:** discovery lists it exactly as created.
/// 3. **open:** `attach` ends `plainConfirmed`: the client record (the session's identity, the
///    client's name, pid and creation time; locally its terminal, remotely the launch token),
///    the window recorded (with its id, for an AppleScript definition), the helper's pid and
///    start time read from its early report, and the session's only client the record's.
/// 4. **open again:** `attach` ends `plainFocused` through the backend's own record (its bound
///    presence check): no window opened, no second client, the window brought forward.
/// 5. **detach:** the backend's bound detach: `detached`, the helper's result present and clean,
///    the record dropped, the client gone within `Budgets.clientGone`; then the window is closed
///    by its recorded id once the helper's process has ended (left as it is when the terminal's
///    own settings already closed it).
/// 6. **move here:** a plain control client of the run's own (`tmux -u -C`, remotely over
///    BatchMode ssh) is the session's only client; a move here confirmed for another key runs
///    nothing (`moveHereNotConfirmed`, no update, no discovery, the client still attached);
///    then a move here with a fresh confirmation ends `plainConfirmed`, the run's client prints
///    `%exit` and ends, and the backend's client is the session's only one.
/// 7. **detach others:** a second plain control client of the run's own; "Detach other
///    clients" ends `detached(count: 1)` no earlier than the client is
///    `minimumLaunchTabAge` (10 s) old, keeping the backend's client; the run's client prints
///    `%exit` and exits 0.
/// 8. **detach again:** as step 5, with the move here's window.
/// 9. **cleanup**, on every way out (a failure, SIGINT, SIGTERM, SIGHUP, the watchdog): see
///    `cleanUp()`.
///
/// Exit statuses: 0 every step passed, 1 a step failed (or a signal stopped the run), 2 the gate
/// refused (the probe also uses 2 for usage), 3 the watchdog stopped the run.
///
/// Safety (PLAN.md *Unattended-run rules*): it creates, attaches, detaches and kills only its
/// own session; it opens windows only through the window layer and closes only those, by the
/// id the layer recorded, only on positive evidence that their process ended; the only signal
/// it sends is SIGTERM to its own helpers, each identified by the pid its launch's own files
/// named and the start time the kernel showed for it; it never types into a window, never
/// launches the app, and never contacts iTerm2. Every wait is bounded.
public actor E2EPlainRun {
  /// The number of steps, cleanup included.
  public static let stepCount = 9
  /// Every step passed.
  public static let passedStatus: Int32 = 0
  /// A step failed, or a signal stopped the run.
  public static let failedStatus: Int32 = 1
  /// The gate refused (nothing was done); the probe uses it for usage errors too.
  public static let refusedStatus: Int32 = 2
  /// The watchdog stopped the run.
  public static let watchdogStatus: Int32 = 3

  /// The run's own waits.
  public struct Budgets: Sendable, Hashable {
    /// How long a plain control client of the run's own may take to attach (remotely ssh
    /// connects and logs in first).
    public var controlClientAttach: Duration
    /// How long such a client may take to end once tmux detached it.
    public var controlClientExit: Duration
    /// How long a detached client may take to leave `list-clients`.
    public var clientGone: Duration
    /// How long a window's helper may take to end before its window is closed.
    public var helperEnd: Duration
    /// How long cleanup keeps asking the run's own helpers that still run, once its session is
    /// gone, to stop (SIGTERM about every second) before it leaves them and reports them.
    public var helperShutdown: Duration
    /// The pause between two looks.
    public var pollInterval: Duration

    /// Budgets of these values (by default 15 s, 10 s, 10 s, 15 s, 15 s and 200 ms).
    public init(
      controlClientAttach: Duration = .seconds(15),
      controlClientExit: Duration = .seconds(10),
      clientGone: Duration = .seconds(10),
      helperEnd: Duration = .seconds(15),
      helperShutdown: Duration = .seconds(15),
      pollInterval: Duration = .milliseconds(200)
    ) {
      self.controlClientAttach = controlClientAttach
      self.controlClientExit = controlClientExit
      self.clientGone = clientGone
      self.helperEnd = helperEnd
      self.helperShutdown = helperShutdown
      self.pollInterval = pollInterval
    } // End of init(controlClientAttach:controlClientExit:clientGone:helperEnd:…:pollInterval:)
  } // End of struct Budgets

  /// The pause between two SIGTERMs to a helper that still runs (one may arrive while it is
  /// between its attach child's end and its wait for Return, where it does not finish the wait).
  static let helperSignalInterval: Duration = .seconds(1)

  /// Everything the run uses.
  public struct Parts: Sendable {
    /// The run's name for its output (`E2EPlainOptions.runName`).
    public var name: String
    /// The command owed to the user when the gate refuses (`E2EPlainOptions.owedCommand`).
    public var owedCommand: String
    /// The terminal definition the backend opens its windows with.
    public var loaded: LoadedTerminalDefinition
    /// This Mac or the SSH destination.
    public var host: HostConfig
    /// tmux on that host.
    public var tmux: any E2EPlainHostTmux
    /// Starts the run's own plain control clients.
    public var startControlClient: E2EPlainControlClientStarter
    /// The window layer: open and focus for the backend, close for the run.
    public var windows: any PlainTerminalWindowLayer & PlainTerminalWindowClosing
    /// Reads the app's facts for the gate (no event sent).
    public var inspector: any TerminalAppInspecting
    /// The helper the windows run.
    public var helperPath: LaunchHelperPath
    /// The launch files.
    public var store: LaunchStore
    /// Discovery (the run's and the backend's).
    public var discovery: any HostDiscovering
    /// The backend's readings and bound commands.
    public var tmuxCommands: PlainTmuxCommands
    /// This Mac's client attributor, as the app passes it.
    public var localClients: (any LocalClientAttributing)?
    /// The backend's budgets.
    public var configuration: AttachCoordinator.Configuration
    /// The kernel start time of a process, as the backend reads its attach children.
    public var processStartTime: @Sendable (Int32) -> ProcessStartTime?
    /// The kernel as the run reads and stops its own helpers.
    public var processes: any E2EPlainHelperProcesses
    /// The run's own waits.
    public var budgets: Budgets
    /// The test session's name (`muxfinder-test-<hex>`).
    public var sessionName: String
    /// Where each output line goes.
    public var output: @Sendable (String) -> Void

    /// Parts of these values; the rest default to the app's (`PlainTmuxCommands()`, no
    /// attributor, the coordinator's budgets, the kernel's start times and processes,
    /// `Budgets()`, a fresh session name, standard output).
    public init(
      name: String,
      owedCommand: String,
      loaded: LoadedTerminalDefinition,
      host: HostConfig,
      tmux: any E2EPlainHostTmux,
      startControlClient: @escaping E2EPlainControlClientStarter,
      windows: any PlainTerminalWindowLayer & PlainTerminalWindowClosing,
      inspector: any TerminalAppInspecting,
      helperPath: LaunchHelperPath,
      store: LaunchStore,
      discovery: any HostDiscovering,
      tmuxCommands: PlainTmuxCommands = PlainTmuxCommands(),
      localClients: (any LocalClientAttributing)? = nil,
      configuration: AttachCoordinator.Configuration = AttachCoordinator.Configuration(),
      processStartTime: @escaping @Sendable (Int32) -> ProcessStartTime? = {
        ProcessStartTime.of($0)
      },
      processes: any E2EPlainHelperProcesses = E2EPlainKernelProcesses(),
      budgets: Budgets = Budgets(),
      sessionName: String = E2EPlainRun.makeSessionName(),
      output: @escaping @Sendable (String) -> Void = { line in
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
      }
    ) {
      self.name = name
      self.owedCommand = owedCommand
      self.loaded = loaded
      self.host = host
      self.tmux = tmux
      self.startControlClient = startControlClient
      self.windows = windows
      self.inspector = inspector
      self.helperPath = helperPath
      self.store = store
      self.discovery = discovery
      self.tmuxCommands = tmuxCommands
      self.localClients = localClients
      self.configuration = configuration
      self.processStartTime = processStartTime
      self.processes = processes
      self.budgets = budgets
      self.sessionName = sessionName
      self.output = output
    } // End of init(name:owedCommand:loaded:host:tmux:startControlClient:windows:…)
  } // End of struct Parts

  /// How the steps ended.
  public enum Ending: Sendable, Equatable {
    /// They ran to the end (passing or not).
    case finished
    /// A signal arrived.
    case signal(Int32)
    /// The watchdog's limit passed.
    case watchdog
  }

  /// Why a step failed, in plain words.
  struct StepFailure: Error {
    /// The explanation.
    let detail: String

    /// Creates a failure.
    init(_ detail: String) {
      self.detail = detail
    }
  }

  /// One client of the session as `list-clients` shows it.
  struct ListedClient: Sendable, Hashable {
    /// Its pid.
    let processID: String
    /// Its creation time (seconds since 1970).
    let created: String
    /// Its name (a terminal for a plain client).
    let name: String
    /// Whether it is a control-mode client.
    let controlMode: Bool

    /// A listed client of these values.
    init(processID: String, created: String, name: String, controlMode: Bool) {
      self.processID = processID
      self.created = created
      self.name = name
      self.controlMode = controlMode
    }

    /// The listing of a plain (not control-mode) client with `client`'s values.
    init(_ client: OtherClient) {
      self.init(
        processID: String(client.processID), created: String(client.created), name: client.name,
        controlMode: false)
    }
  } // End of struct ListedClient

  /// A launch's helper as the launch's own files named it (its early report, else its result),
  /// kept by launch token whatever became of the launch's window: its pid, and a moment it is
  /// known to have run with that pid, so that a process at the pid that started no later is the
  /// helper (pids are unique among live processes); and its kernel start time once seen so.
  struct HelperProcess: Sendable, Hashable {
    /// The helper's pid.
    let processID: Int32
    /// When it is known to have run with that pid: its attach child's kernel start time (the
    /// early report; the helper started the child), or its result's end time.
    let aliveAt: ProcessStartTime
    /// Its kernel start time, once read while it ran within `aliveAt`; `nil` until then.
    var start: ProcessStartTime?
  }

  /// Whether a helper of the run's still runs, as the kernel shows it now.
  enum HelperLiveness: Sendable, Hashable {
    /// It runs: its pid still has its start time.
    case running
    /// It ended, on positive evidence: no process has its pid, or one with another start time
    /// than the one recorded does.
    case ended
    /// Not known: the kernel's answer could not be read, or the process at its pid started
    /// after the helper's own files, so it cannot be told to be the helper.
    case unknown
  }

  /// One window the run opened (seen in the backend's updates).
  struct OpenedWindow: Sendable {
    /// The launch that opened it.
    let launchID: LaunchToken
    /// The window, as the layer returned it.
    let window: PlainTerminalWindow
    /// Whether it was closed (or found already closed).
    var closed = false
  }

  /// What looking for step 1's session by its exact name found.
  enum SessionRecovery: Sendable, Equatable {
    /// It, created since `new-session` started.
    case found(CreatedSession)
    /// The listing showed no such session (or no server), or step 1 never ran.
    case notFound
    /// The listing failed: whether it exists cannot be told.
    case unknown
  }

  /// The parts.
  let parts: Parts
  /// The backend under test, built from the parts as the app builds a plain one.
  let backend: PlainTerminalBackend
  /// The parts' discovery, counted.
  let discovery: E2EPlainCountingDiscovery
  /// The backend's updates.
  let updates = E2EPlainUpdateLog()
  /// The test session's name.
  public nonisolated let sessionName: String
  /// The run's name.
  public nonisolated let name: String

  /// The created session, once known.
  var created: CreatedSession?
  /// When step 1 started `new-session` (seconds since 1970).
  var creationStartedAt: Int64?
  /// The attach target discovery found.
  var target: AttachTarget?
  /// The backend's confirmed client, while it holds one.
  var record: PlainClientRecord?
  /// The windows the run opened, in order.
  var openedWindows: [OpenedWindow] = []
  /// The helper of each launch whose own files named one, by launch token.
  var helpers: [LaunchToken: HelperProcess] = [:]
  /// Every launch the run made (results and updates), so cleanup takes what nobody took.
  var launchIDs: [LaunchToken] = []
  /// The run's own plain control clients.
  var controlClients: [any E2EPlainControlClient] = []
  /// The gate's refusal at a side effect during the run, if any.
  var gateRefusal: PlainRunGate.Refusal?
  /// `tmux -V`, once the header asked.
  var tmuxVersion: String?
  /// Whether setup succeeded.
  var setUp = false
  /// Steps that passed.
  public internal(set) var passedCount = 0
  /// The note lines of the current step.
  var notes: [String] = []

  /// A run over `parts`.
  public init(parts: Parts) {
    self.parts = parts
    sessionName = parts.sessionName
    name = parts.name
    let counting = E2EPlainCountingDiscovery(base: parts.discovery)
    discovery = counting
    let updates = self.updates
    backend = PlainTerminalBackend(
      loaded: parts.loaded, windows: parts.windows, helperPath: parts.helperPath,
      store: parts.store, discovery: counting, tmux: parts.tmuxCommands,
      configuration: parts.configuration, processStartTime: parts.processStartTime,
      localClients: parts.localClients, onUpdate: { updates.record($0) })
  } // End of init(parts:)

  /// A fresh test session name, `muxfinder-test-<8 hex digits>`.
  public static func makeSessionName() -> String {
    "muxfinder-test-" + String(format: "%08x", UInt32.random(in: .min ... .max))
  }

  /// Writes `line` to the parts' output.
  nonisolated func output(_ line: String) {
    parts.output(line)
  }

  // MARK: - The whole run

  /// The gate's refusal for `loaded`'s app with facts read now through `inspector` (no event
  /// sent), or `nil` when the run may go ahead.
  @MainActor
  public static func gateRefusal(
    for loaded: LoadedTerminalDefinition,
    inspector: any TerminalAppInspecting
  ) -> PlainRunGate.Refusal? {
    PlainRunGate.check(
      loaded.definition, facts: TerminalAppFacts.read(for: loaded.definition, inspector: inspector))
  }

  /// The whole run: the gate (2 with the reason and the owed command, nothing done), the
  /// header, the steps raced against `interrupts` (signal numbers) and the watchdog's `limit`,
  /// cleanup on every way out, the summary. Returns the exit status.
  public func execute(limit: Duration, interrupts: AsyncStream<Int32>? = nil) async -> Int32 {
    let loaded = parts.loaded
    let inspector = parts.inspector
    let facts = await MainActor.run {
      TerminalAppFacts.read(for: loaded.definition, inspector: inspector)
    }
    if let refusal = PlainRunGate.check(loaded.definition, facts: facts) {
      output("\(name): not run: \(refusal.message)")
      output(
        "\(name): nothing was created, written, discovered or sent; owed to the user: "
          + parts.owedCommand)
      return Self.refusedStatus
    }
    let started = ContinuousClock.now
    await printHeader(facts)
    let steps = Task { await self.runSteps() }
    let ending = await Self.waitForEnding(of: steps, interrupts: interrupts, limit: limit)
    switch ending {
    case .finished: break
    case .signal(let number): output("Interrupted by signal \(number); cleaning up.")
    case .watchdog: output("The run took longer than \(limit); cleaning up.")
    }
    await steps.value
    await Task { await self.cleanUp() }.value
    if let gateRefusal {
      output(
        "\(name): the window layer's recheck of the gate refused a side effect during the run "
          + "(\(gateRefusal.message)); the run stopped and cleaned up what it made")
    }
    let total = Self.milliseconds(ContinuousClock.now - started)
    output(
      "\(name): \(passedCount) of \(Self.stepCount) steps passed in "
        + "\(String(format: "%.1f", Double(total) / 1000)) s")
    return Self.exitStatus(passed: passedCount, ending: ending)
  } // End of func execute(limit:interrupts:)

  /// The exit status for `passed` steps and how the steps ended.
  public static func exitStatus(passed: Int, ending: Ending) -> Int32 {
    switch ending {
    case .watchdog: return watchdogStatus
    case .signal: return failedStatus
    case .finished: return passed == stepCount ? passedStatus : failedStatus
    }
  }

  /// Waits until the steps finish, a signal arrives on `interrupts` or `limit` passes; in the
  /// last two cases the steps are cancelled.
  static func waitForEnding(
    of steps: Task<Void, Never>,
    interrupts: AsyncStream<Int32>?,
    limit: Duration
  ) async -> Ending {
    await withTaskGroup(of: Ending.self) { group in
      group.addTask {
        await steps.value
        return .finished
      }
      if let interrupts {
        group.addTask {
          for await number in interrupts { return .signal(number) }
          await steps.value
          return .finished
        }
      }
      group.addTask {
        do {
          try await Task.sleep(for: limit)
          return .watchdog
        } catch {
          return .finished
        }
      }
      let first = await group.next() ?? .finished
      if first != .finished { steps.cancel() }
      group.cancelAll()
      return first
    } // End of task group racing the steps against signals and the watchdog
  } // End of static func waitForEnding(of:interrupts:limit:)

  /// Prints the versions and facts this run uses.
  func printHeader(_ facts: TerminalAppFacts) async {
    tmuxVersion = await parts.tmux.version()
    let definition = parts.loaded.definition
    output(
      "\(name): macOS \(ProcessInfo.processInfo.operatingSystemVersionString), "
        + "\(definition.displayName) \(facts.version ?? "unknown") (running, Automation "
        + "\(facts.automation.kind)), \(tmuxVersion ?? "tmux unknown") \(parts.tmux.location), "
        + "helper \(parts.helperPath.path), session \(sessionName)")
  } // End of func printHeader(_:)

  // MARK: - Steps

  /// Setup, then steps 1–8, stopping at the first failure. Cleanup is `cleanUp()`.
  public func runSteps() async {
    guard setUpRun() else { return }
    guard await step(1, "create session", { try await self.createSession() }),
      await step(2, "discover", { try await self.discoverSession() }),
      await step(3, "open", { try await self.openStep() }),
      await step(4, "open again", { try await self.openAgainStep() }),
      await step(5, "detach", { try await self.detachStep() }),
      await step(6, "move here", { try await self.moveHereStep() }),
      await step(7, "detach others", { try await self.detachOthersStep() }),
      await step(8, "detach again", { try await self.detachStep() })
    else { return }
  } // End of func runSteps()

  /// Checks that tmux answered on the host (remotely: over BatchMode ssh).
  func setUpRun() -> Bool {
    guard tmuxVersion != nil else {
      output(
        "FAIL setup: tmux -V did not answer \(parts.tmux.location); check that tmux is "
          + "installed (and, remotely, that the host is reachable with key authentication)")
      return false
    }
    setUp = true
    output(
      "setup: the \(parts.loaded.definition.displayName) app runs and the gate let the run go "
        + "ahead; the window layer checks it again before every open, focus and close")
    return true
  } // End of func setUpRun()

  /// Runs one step and prints its PASS or FAIL line, then its note lines. Returns whether it
  /// passed.
  func step(
    _ number: Int,
    _ title: String,
    _ body: () async throws -> String
  ) async -> Bool {
    let start = ContinuousClock.now
    notes.removeAll()
    let passed: Bool
    let detail: String
    do {
      detail = try await body()
      passed = true
    } catch let failure as StepFailure {
      (passed, detail) = (false, failure.detail)
    } catch is CancellationError {
      (passed, detail) = (false, "interrupted")
    } catch {
      (passed, detail) = (false, "\(error)")
    }
    output(
      "\(passed ? "PASS" : "FAIL") \(number) \(title) "
        + "(\(Self.milliseconds(ContinuousClock.now - start)) ms): \(detail)")
    for line in notes { output("  note: \(line)") }
    if passed { passedCount += 1 }
    return passed
  } // End of func step(_:_:_:)

  /// Step 1: the session, one window running `sleep 600`.
  func createSession() async throws -> String {
    creationStartedAt = Int64(Date().timeIntervalSince1970)
    let made = try await parts.tmux.run([
      "new-session", "-d", "-P", "-F", CreatedSession.format, "-s", sessionName, "sleep", "600",
    ])
    guard made.succeeded, made.lines.count == 1, let session = CreatedSession.parse(made.lines[0]),
      session.name == sessionName
    else {
      if case .found(let recovered) = await recoverCreatedSession() { created = recovered }
      throw StepFailure("new-session failed: \(Self.printable(made.standardError))")
    }
    created = session
    return "\(session.sessionID) created with one window running sleep 600"
  } // End of func createSession()

  /// The session step 1 tried to create, found by its exact generated name among the sessions
  /// created since `new-session` started; `notFound` also when step 1 never ran, `unknown` when
  /// the listing failed.
  func recoverCreatedSession() async -> SessionRecovery {
    guard let started = creationStartedAt else { return .notFound }
    guard let lines = await listSessions(format: CreatedSession.format) else { return .unknown }
    let margin: Int64 = parts.host.mode == .local ? 2 : 120
    return CreatedSession.find(
      named: sessionName, createdNoEarlierThan: started - margin, in: lines
    ).map(SessionRecovery.found) ?? .notFound
  } // End of func recoverCreatedSession()

  /// `list-sessions -F <format>` on the host: its lines; none when tmux answered that no server
  /// runs (exit 1 with `ErrorClassifier.isNoServerMessage`'s error, a genuine absence of every
  /// session); `nil` when the listing failed otherwise (tmux's or ssh's error, a timeout), so
  /// nothing is known.
  func listSessions(format: String) async -> [String]? {
    guard let listing = try? await parts.tmux.run(["list-sessions", "-F", format]) else {
      return nil
    }
    if listing.succeeded { return listing.lines }
    let firstLine = listing.standardError.split(separator: "\n").first.map(String.init) ?? ""
    guard listing.status == 1, !listing.timedOut, ErrorClassifier.isNoServerMessage(firstLine)
    else { return nil }
    return []
  } // End of func listSessions(format:)

  /// Step 2: discovery lists the session exactly as created, with its one window.
  func discoverSession() async throws -> String {
    let (session, duration) = try await discoverCreated()
    guard session.windowCount == 1 else {
      throw StepFailure("discovery reported \(session.windowCount) windows, not 1")
    }
    target = AttachTarget(host: parts.host, session: session)
    return "\(session.key.sessionID) found as created (\(Self.milliseconds(duration)) ms)"
  }

  /// The created session as discovery lists it now, and how long discovery took.
  func discoverCreated() async throws -> (DiscoveredSession, Duration) {
    guard let created else { throw StepFailure("no test session") }
    let result = try await discovery.discover(parts.host)
    guard case .ok(let sessions) = result.status else {
      throw StepFailure("discovery reported \(result.status.kind)")
    }
    guard let session = sessions.first(where: { $0.key.sessionID == created.sessionID }),
      created.matches(session)
    else { throw StepFailure("discovery did not report the created session as it was") }
    return (session, result.duration)
  } // End of func discoverCreated()

  /// Step 3: the first open, confirmed from evidence.
  func openStep() async throws -> String {
    guard let target else { throw StepFailure("no target from discovery") }
    let result = await backend.attach(target)
    let client = try confirmed(result, operation: "open")
    let window = try recordConfirmed(result, client: client)
    let clients = try await clients(of: target.key.sessionID)
    guard clients == [ListedClient(client.client)] else {
      throw StepFailure(
        "the session's clients after the open: \(clients.count), not only the backend's plain "
          + "client")
    }
    let states = updates.stateKinds(of: result.launchID)
    guard states.filter({ $0 == "plainLaunched" }).count == 1 else {
      throw StepFailure("states \(states.joined(separator: " → ")): not one window opened")
    }
    notes.append("states \(states.joined(separator: " → ")); \(focusText(result))")
    return "confirmed in \(ms(result.timings.confirmed)) ms: \(describe(client)), window "
      + "\(window.windowID ?? "without id") recorded with its helper"
  } // End of func openStep()

  /// Step 4: a second open focuses the backend's own window, opening nothing.
  func openAgainStep() async throws -> String {
    guard let target, let record else { throw StepFailure("no attachment") }
    let mark = updates.count
    let result = await backend.attach(target)
    noteLaunches(result)
    try checkGate(result)
    guard result.state == .plainFocused(client: record) else {
      throw StepFailure(ended(result, operation: "second open"))
    }
    let opened = updates.updates(after: mark).filter {
      if case .plainLaunched = $0.state { return true }
      return false
    }
    guard opened.isEmpty else { throw StepFailure("the second open opened a window") }
    guard result.plainWindowFocus == .plainWindowFocused else {
      throw StepFailure("its window was not brought forward: \(focusText(result))")
    }
    let clients = try await clients(of: target.key.sessionID)
    guard clients == [ListedClient(record.client)] else {
      throw StepFailure("the session has \(clients.count) clients, not only the backend's")
    }
    return "plainFocused through its own record (the bound presence check): no window opened, "
      + "no second client, its window brought forward"
  } // End of func openAgainStep()

  /// Steps 5 and 8: the backend's bound detach, then the window closed by its recorded id once
  /// its helper ended.
  func detachStep() async throws -> String {
    guard let target, let record else { throw StepFailure("no attachment") }
    let start = ContinuousClock.now
    let result = await backend.detach(session: target.key, on: parts.host)
    guard result.outcome == .detached, let plain = result.plainDetach, plain.outcome == .detached
    else {
      let failure = result.plainDetach?.failure.map { " (\($0.kind))" } ?? ""
      throw StepFailure("the detach ended \(result.outcome.rawValue)\(failure)")
    }
    self.record = nil
    guard let helperResult = plain.helperResult else {
      throw StepFailure("the helper's result did not arrive within the result budget")
    }
    guard helperResult.exitStatus == 0, helperResult.failure == nil else {
      throw StepFailure(
        "the helper's result: exit \(helperResult.exitStatus) "
          + "(\(helperResult.failure?.kind ?? "no failure"))")
    }
    guard await backend.attachment(of: target.key) == nil else {
      throw StepFailure("the backend still holds its record of the session")
    }
    let id = target.key.sessionID
    let left = try await poll(within: parts.budgets.clientGone) { () -> [ListedClient]? in
      let clients = try await self.clients(of: id)
      return clients.contains(ListedClient(record.client)) ? nil : clients
    }
    guard let left else {
      throw StepFailure(
        "the client was still attached \(parts.budgets.clientGone) after the detach")
    }
    guard left.isEmpty else { throw StepFailure("the session kept \(left.count) other client(s)") }
    let gone = Self.milliseconds(ContinuousClock.now - start)
    let closed = await closeWindow(of: record.launchID)
    guard closed.passes else { throw StepFailure("its window: \(closed.text)") }
    return "detached with the bound detach, the client gone within \(gone) ms, the helper's "
      + "result exit 0, the record dropped; the window \(closed.text)"
  } // End of func detachStep()

  /// Step 6: Move here over a plain control client of the run's own.
  func moveHereStep() async throws -> String {
    guard let target, await backend.attachment(of: target.key) == nil else {
      throw StepFailure("the backend still holds the session")
    }
    let id = target.key.sessionID
    let plain = try startControlClient()
    let plainListed = try await waitForControlClient(plain, besides: [], session: id)
    // A confirmation for another key (the same tmux session, another host entry) runs nothing.
    let otherKey = SessionKey(hostID: UUID(), server: target.key.server, sessionID: id)
    let mark = updates.count
    let discoveries = discovery.count
    let refused = await backend.moveHere(target, confirmation: .detachOtherClients(of: otherKey))
    noteLaunches(refused)
    guard refused.failure == .moveHereNotConfirmed else {
      throw StepFailure(ended(refused, operation: "stale move here"))
    }
    guard updates.count == mark, discovery.count == discoveries else {
      throw StepFailure(
        "the stale move here published \(updates.count - mark) update(s) and ran "
          + "\(discovery.count - discoveries) discovery call(s)")
    }
    guard plain.isRunning, try await clients(of: id) == [plainListed] else {
      throw StepFailure("the session's clients changed after the stale move here")
    }
    // The move here with a fresh confirmation.
    let (session, _) = try await discoverCreated()
    let fresh = AttachTarget(host: parts.host, session: session)
    self.target = fresh
    let moved = await backend.moveHere(fresh, confirmation: .detachOtherClients(of: fresh.key))
    let client = try confirmed(moved, operation: "move here")
    _ = try recordConfirmed(moved, client: client)
    guard let ended = await plain.waitForExit(within: parts.budgets.controlClientExit) else {
      throw StepFailure(
        "the run's control client was still running \(parts.budgets.controlClientExit) after the "
          + "move here")
    }
    guard plain.sawExitNotification else {
      throw StepFailure("the run's control client ended (\(ended)) without printing %exit")
    }
    let only = try await poll(within: .seconds(3)) { () -> Bool? in
      try await self.clients(of: id) == [ListedClient(client.client)] ? true : nil
    }
    guard only == true else {
      throw StepFailure("the backend's client is not the session's only one after the move here")
    }
    return "a move here confirmed for another key ran nothing; the fresh one ended plainConfirmed "
      + "in \(ms(moved.timings.confirmed)) ms (\(describe(client))); the run's control client "
      + "printed %exit and ended (\(ended)); the backend's client is the session's only one"
  } // End of func moveHereStep()

  /// Step 7: "Detach other clients" with a second plain control client of the run's own.
  func detachOthersStep() async throws -> String {
    guard let target, let record else { throw StepFailure("no attachment") }
    let id = target.key.sessionID
    let kept = ListedClient(record.client)
    let started = ContinuousClock.now
    let plain = try startControlClient()
    _ = try await waitForControlClient(plain, besides: [kept], session: id)
    let callStart = ContinuousClock.now
    let result = await backend.detachOtherClients(
      of: target, confirmation: .detachOtherClients(of: target.key))
    let returned = ContinuousClock.now
    guard result.outcome == .detached(count: 1) else {
      var problem = ""
      if case .checkFailed(let failure) = result.outcome {
        problem = " (\(failure.kind): \(failure.detail ?? "-"))"
      }
      throw StepFailure("the call ended \(result.outcome.kind)\(problem), not detached(count: 1)")
    }
    guard result.keptPlainClient == record, result.listedOthers == 1, result.detachedClients == 1
    else { throw StepFailure("the call kept another client, or listed or detached more") }
    let minimum = parts.configuration.minimumLaunchTabAge
    guard returned - started >= minimum else {
      throw StepFailure(
        "the call returned \(Self.milliseconds(returned - started)) ms after the client was "
          + "started, before it could be \(minimum) old")
    }
    guard let ended = await plain.waitForExit(within: parts.budgets.controlClientExit) else {
      throw StepFailure("the run's control client was still running after the call")
    }
    guard plain.sawExitNotification, ended == .exited(0) else {
      throw StepFailure(
        "the run's control client ended \(ended) (%exit seen: \(plain.sawExitNotification))")
    }
    guard try await clients(of: id) == [kept] else {
      throw StepFailure("the backend's client is not the session's only one after the call")
    }
    notes.append(
      "the call took \(Self.milliseconds(returned - callStart)) ms, waiting "
        + "\(Self.milliseconds(result.ageWait)) ms for the client to be \(minimum) old")
    return "detached(count: 1) keeping the backend's client; the run's control client printed "
      + "%exit and exited 0"
  } // End of func detachOthersStep()

  // MARK: - Shared step parts

  /// The confirmed client of `result`, after the gate's recheck; a step failure otherwise.
  func confirmed(_ result: AttachResult, operation: String) throws -> PlainClientRecord {
    noteLaunches(result)
    try checkGate(result)
    guard case .plainConfirmed(let client) = result.state else {
      throw StepFailure(ended(result, operation: operation))
    }
    return client
  }

  /// Checks `client` against the run's session and launch, records it and its window's helper,
  /// and returns the window.
  func recordConfirmed(
    _ result: AttachResult,
    client: PlainClientRecord
  ) throws -> PlainTerminalWindow {
    guard let created else { throw StepFailure("no test session") }
    syncWindows()
    guard let index = openedWindows.firstIndex(where: { $0.launchID == result.launchID }) else {
      throw StepFailure("the confirmed launch reported no window")
    }
    let window = openedWindows[index].window
    if case .appleScript = parts.loaded.definition.open, window.windowID == nil {
      throw StepFailure("the window has no id, so it could never be closed by its recorded id")
    }
    guard client.launchID == result.launchID, client.session == BoundSessionIdentity(created) else {
      throw StepFailure("the client record names another launch or session")
    }
    switch parts.host.mode {
    case .local:
      guard client.token == nil, let path = client.terminalPath, client.client.name == path else {
        throw StepFailure("the local client record lacks its terminal")
      }
    case .ssh:
      guard client.token == result.launchID, client.terminalPath == nil else {
        throw StepFailure("the remote client record lacks the launch token")
      }
    }
    guard let report = try? parts.store.peekReport(result.launchID) else {
      throw StepFailure("the helper's early report could not be read")
    }
    if helpers[result.launchID]?.start == nil {
      helpers[result.launchID] = HelperProcess(
        processID: report.helperPID, aliveAt: report.attachChildStartTime)
    }
    switch liveness(ofHelperOf: result.launchID) {
    case .running?:
      break
    case .ended?:
      throw StepFailure("the helper is not running although its client was confirmed")
    case .unknown?, nil:
      throw StepFailure(
        "the helper's process could not be read (or is not the report's), so its window could "
          + "never be closed on evidence that it ended")
    }
    record = client
    return window
  } // End of func recordConfirmed(_:client:)

  /// Fails the step when the window layer's recheck of the gate refused a side effect of
  /// `result` (its open, or the focus after it).
  func checkGate(_ result: AttachResult) throws {
    var refusal = PlainRunGate.refusal(of: result)
    if refusal == nil, case .terminalWindow(let error)? = result.failure {
      refusal = Self.gateRefusal(in: error)
    }
    if refusal == nil, case .plainWindowFailed(let error)? = result.plainWindowFocus {
      refusal = Self.gateRefusal(in: error)
    }
    guard let refusal else { return }
    gateRefusal = refusal
    throw StepFailure("the gate's recheck at the side effect refused: \(refusal.message)")
  } // End of func checkGate(_:)

  /// The gate's refusal a window layer failure stands for: the unattended policy's own, an app
  /// that stopped running, or a permission found denied; `nil` for any other failure.
  static func gateRefusal(in error: PlainTerminalWindowError) -> PlainRunGate.Refusal? {
    switch error {
    case .unattendedRunRefused(_, let refusal): return refusal
    case .appNotRunning: return .notRunning
    case .permissionDenied: return .permissionNotGranted(.denied)
    default: return nil
    }
  }

  /// Notes `result`'s launch and every launch and window the updates showed so far, and records
  /// the helper each launch's own files name already (`trackHelpers()`).
  func noteLaunches(_ result: AttachResult) {
    if !launchIDs.contains(result.launchID) { launchIDs.append(result.launchID) }
    syncWindows()
    trackHelpers()
  }

  /// Adds every window and launch the updates showed and the run does not know yet.
  func syncWindows() {
    for id in updates.launchIDs where !launchIDs.contains(id) { launchIDs.append(id) }
    for (launchID, window) in updates.windows
    where !openedWindows.contains(where: { $0.launchID == launchID }) {
      openedWindows.append(OpenedWindow(launchID: launchID, window: window))
    }
  }

  /// Starts a plain control client of the run's own attached to the test session.
  func startControlClient() throws -> any E2EPlainControlClient {
    let client = try parts.startControlClient(
      parts.tmux.controlClientCommand(attachingTo: sessionName))
    controlClients.append(client)
    return client
  }

  /// Waits until the session's clients are `kept` and one control client more (locally the
  /// one with `plain`'s pid) and returns that one.
  func waitForControlClient(
    _ plain: any E2EPlainControlClient,
    besides kept: [ListedClient],
    session id: TmuxSessionID
  ) async throws -> ListedClient {
    let found = try await poll(within: parts.budgets.controlClientAttach) { () -> ListedClient? in
      guard plain.isRunning else {
        throw StepFailure(
          "the run's control client ended before attaching (\(plain.errorText.prefix(120)))")
      }
      let clients = try await self.clients(of: id)
      let others = clients.filter { !kept.contains($0) }
      guard clients.count == kept.count + 1, kept.allSatisfy(clients.contains),
        let other = others.first, other.controlMode
      else { return nil }
      return other
    }
    guard let found else {
      throw StepFailure(
        "the run's control client did not attach within \(parts.budgets.controlClientAttach)")
    }
    if parts.host.mode == .local, found.processID != String(plain.processID) {
      throw StepFailure("the session's new client is not the run's control client")
    }
    return found
  } // End of func waitForControlClient(_:besides:session:)

  /// The clients of the session `id`, sorted by pid.
  func clients(of id: TmuxSessionID) async throws -> [ListedClient] {
    let listed = try await parts.tmux.run([
      "list-clients", "-t", id.rawValue, "-F",
      "#{client_pid}\t#{client_created}\t#{client_control_mode}\t#{client_name}",
    ])
    guard listed.succeeded else { throw StepFailure("list-clients failed") }
    var clients: [ListedClient] = []
    for line in listed.lines {
      let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
        .map(String.init)
      guard fields.count == 4 else { throw StepFailure("list-clients printed a malformed line") }
      clients.append(
        ListedClient(
          processID: fields[0], created: fields[1], name: fields[3], controlMode: fields[2] == "1"))
    } // End of loop over the listed clients
    return clients.sorted { $0.processID < $1.processID }
  } // End of func clients(of:)

  /// Polls `condition` every `pollInterval` until it returns a value or `limit` passes.
  func poll<Value: Sendable>(
    within limit: Duration,
    _ condition: () async throws -> Value?
  ) async throws -> Value? {
    let deadline = ContinuousClock.now + limit
    while true {
      if let value = try await condition() { return value }
      guard ContinuousClock.now < deadline else { return nil }
      try await Task.sleep(for: parts.budgets.pollInterval)
    }
  } // End of func poll(within:_:)

  /// How an attach ended, for a failure line: state and failure kinds only.
  func ended(_ result: AttachResult, operation: String) -> String {
    "the \(operation) ended \(result.state.kind): \(result.failure?.kind ?? "-")"
      + (result.failure?.detail.map { " (\($0))" } ?? "")
  }

  /// A client record for a PASS line: ids and numbers only.
  func describe(_ client: PlainClientRecord) -> String {
    let place =
      client.token != nil ? "the launch token found on the host" : "its terminal from the report"
    return "client pid \(client.client.processID) created \(client.client.created), \(place)"
  }

  /// How bringing the window forward went.
  func focusText(_ result: AttachResult) -> String {
    switch result.plainWindowFocus {
    case .plainWindowFailed(let error)?: return "focus failed (\(error.kind))"
    case let focus?: return "focus \(focus.kind)"
    case nil: return "no focus"
    }
  }

  /// Milliseconds of an optional duration, or -1.
  func ms(_ duration: Duration?) -> Int {
    duration.map(Self.milliseconds) ?? -1
  }

  /// Whole milliseconds of `duration`.
  static func milliseconds(_ duration: Duration) -> Int {
    Int(duration / .milliseconds(1))
  }

  /// At most the first 200 characters of `text`, printable ASCII only (anything else `?`).
  static func printable(_ text: String) -> String {
    String(
      text.unicodeScalars.prefix(200).map { (0x20...0x7E).contains($0.value) ? Character($0) : "?" }
    )
  }
} // End of actor E2EPlainRun
