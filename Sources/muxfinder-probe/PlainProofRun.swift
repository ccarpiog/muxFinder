import Darwin
import Foundation
import MuxFinderCore

/// `muxfinder-probe plain-proof --local | --ssh <destination>`: the harness of PLAN.md D38's
/// proof (Phase I-12a). Plain tmux clients (`PlainLaunch`) run on pseudo-terminals the harness
/// opens itself (`ProofTerminal`, `ProofChild`), standing in for a terminal app's window; this
/// Mac's clients are `<tmux>` with `PlainLaunch.localAttachArguments(session:detachingOthers:)`,
/// a remote host's are `/usr/bin/ssh -t` (discovery's noninteractive options, so BatchMode and
/// key authentication, plus no connection sharing) running `PlainLaunch.remoteScript` with a
/// token of their own. Each client is told apart by `PlainClientIdentification`: locally by its
/// terminal (`client_tty`), remotely by the token at the end of its parent shell's arguments,
/// read over noninteractive ssh.
///
/// **Bound commands** (PLAN.md D38). Every attach and every detach is one tmux command that the
/// server checks and carries out with nothing in between, so neither can reach a session or a
/// client that took the recorded one's id or terminal meanwhile: an attach is `if-shell -F -t
/// <id> <condition> "attach-session [-d] -t '<id>'" "run-shell 'exit 65'"` (locally the
/// session's id, creation time, server pid and start time, socket path and `muxfinder-test-*`
/// name; remotely, after the guard's check, its four values), so it attaches, or for a move
/// here detaches the others, only while the session is exactly the one step 1 recorded, and
/// otherwise exits 65; a detach is `PlainClientDetach` (the session's identity and exactly one
/// client of that name with the recorded pid and creation time in that session), one tmux call
/// locally and one ssh call remotely, and reports whether it detached.
///
/// Steps (each prints one PASS or FAIL line, with note lines; the first failure stops the run,
/// then cleanup runs):
/// 1. **create session:** `muxfinder-test-<hex>`, one window running `sleep 600`.
/// 2. **client identified:** client A attaches; the reading confirms exactly one client, the
///    session's only one (locally with A's own pid).
/// 3. **no client, a stale attach refused:** a reading for a terminal with no client (locally,
///    a second pseudo-terminal of the harness), or a token no client carries (remotely), finds
///    none; then client S attaches there with the recorded identity but the server's start
///    time one second earlier (as a restarted server's session with the same id would differ):
///    its child exits 65 by itself (locally the bound attach, remotely the guard), the reading
///    still finds none and the session keeps its one client.
/// 4. **second client told apart:** client B attaches; each reading confirms its own client,
///    two different clients, the session's two.
/// 5. **two candidates refused:** client A2 carries A's evidence (locally on A's terminal,
///    remotely with A's token); A's reading finds two candidates and confirms neither; locally,
///    where A2 also has A's client name, the bound detach of A detaches nothing (two clients of
///    that name) and all 3 stay; A2 is ended (SIGTERM to its group) and A's reading confirms A
///    again.
/// 6. **detach one identified client:** the bound detach of A with its creation time one
///    second later (as a client that took A's terminal afterwards would differ) detaches
///    nothing and both stay; the bound detach of A then detaches it: A's child exits 0 by
///    itself, B stays attached and its child runs.
/// 7. **move here:** client M0, a move here with step 3's stale identity, exits 65 and B stays
///    attached; client M attaches with the bound `attach-session -d` (PLAN.md D21); M is
///    confirmed as the session's only client and B's child exits 0 by itself (tmux detached
///    it).
/// 8. **detach the moved client:** the bound detach of M; M's child exits 0, the session stays
///    with no client.
///
/// **Cleanup** (step 9, on every way out, SIGINT and SIGTERM included): every child still
/// running is ended (SIGTERM, then SIGKILL, and reaped), every pseudo-terminal closed, the
/// session killed only while it is still exactly the created one; then no session of that
/// name and no child process of the harness may be left.
///
/// Safety (PLAN.md *Unattended-run rules*): it creates, attaches, detaches and kills only its
/// own session, through bound commands only, targets only clients it identified as its own,
/// never contacts iTerm2 or any
/// terminal app, writes nothing on the remote host, and never shows or keeps a byte its
/// clients wrote to their terminals. Every wait is bounded.
actor PlainProofRun {
  /// The number of steps, cleanup included.
  static let stepCount = 9
  /// How long a new client may take to be identified (remotely ssh connects and logs in).
  static let localAttachBudget: Duration = .seconds(5)
  /// The same, remotely.
  static let remoteAttachBudget: Duration = .seconds(20)
  /// How long a detached client's child may take to exit by itself.
  static let exitBudget: Duration = .seconds(10)
  /// How long an ended client may take to leave the session's listing.
  static let leaveBudget: Duration = .seconds(10)
  /// The pause between two readings.
  static let pollInterval: Duration = .milliseconds(200)
  /// The terminal type the clients run with.
  static let terminalType = "xterm-256color"
  /// Variables that name the terminal the harness itself runs in, removed from the clients'
  /// environment so they see only `terminalType`.
  static let terminalVariables = [
    "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "ITERM_SESSION_ID",
    "ITERM_PROFILE", "LC_TERMINAL", "LC_TERMINAL_VERSION", "COLORTERM", "TERM_FEATURES",
  ]

  /// Which host.
  let kind: E2EBuryRun.Kind
  /// tmux on the host under test.
  let tmux: any HarnessTmux
  /// tmux on this Mac, for `--local`.
  let localTmux: TestTmux?
  /// tmux on the remote host, for `--ssh`.
  let remoteTmux: RemoteTestTmux?
  /// The clients' environment.
  let environment: [String: String]
  /// The test session's name.
  let sessionName = "muxfinder-test-" + String(format: "%08x", UInt32.random(in: .min ... .max))

  /// What tells a client apart.
  enum Evidence: Sendable {
    /// Its terminal's path, as `client_tty` (this Mac).
    case terminal(String)
    /// The token at the end of its parent shell's arguments (a remote host).
    case token(LaunchToken)
  }

  /// One plain client of the run.
  struct Client: Sendable {
    /// Its label in the output.
    let label: String
    /// Its launch token (sent to the remote host only).
    let token: LaunchToken
    /// The pseudo-terminal it runs on.
    let terminal: ProofTerminal
    /// The child.
    let child: ProofChild
    /// What tells it apart.
    let evidence: Evidence
  }

  /// The created session, once known.
  private var created: CreatedSession?
  /// When step 1 started `new-session` (seconds since 1970).
  private var creationStartedAt: Int64?
  /// Every pseudo-terminal the run opened.
  private var terminals: [ProofTerminal] = []
  /// Every client the run started, in order.
  private var clients: [Client] = []
  /// The tmux client each label was identified as.
  private var identified: [String: OtherClient] = [:]
  /// How long each reading took, in milliseconds.
  private var readingTimes: [Int] = []
  /// `tmux -V`, once the header asked.
  private var tmuxVersion: String?
  /// Whether setup succeeded.
  private var setUp = false
  /// Steps that passed.
  private(set) var passedCount = 0
  /// The note lines of the current step.
  private var lines: [String] = []

  /// Creates the run.
  init(
    kind: E2EBuryRun.Kind,
    tmux: any HarnessTmux,
    localTmux: TestTmux?,
    remoteTmux: RemoteTestTmux?
  ) {
    self.kind = kind
    self.tmux = tmux
    self.localTmux = localTmux
    self.remoteTmux = remoteTmux
    var environment = DiscoveryProbe.localEnvironment(
      base: ProcessInfo.processInfo.environment)
    for name in Self.terminalVariables { environment[name] = nil }
    environment["TERM"] = Self.terminalType
    self.environment = environment
  } // End of init(kind:tmux:localTmux:remoteTmux:)

  /// The command's name for the output.
  nonisolated var name: String {
    kind == .local ? "plain-proof --local" : "plain-proof --ssh"
  }

  /// Writes `line` to standard output at once.
  nonisolated func output(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
  }

  /// Prints the versions this run uses.
  func printHeader() async {
    tmuxVersion = await tmux.version()
    output(
      "\(name): macOS \(ProcessInfo.processInfo.operatingSystemVersionString), "
        + "\(tmuxVersion ?? "tmux unknown") \(tmux.location), session \(sessionName); plain "
        + "clients on pseudo-terminals of its own (TERM \(Self.terminalType), 80x24, output "
        + "discarded); no terminal app, no iTerm2")
  } // End of func printHeader()

  // MARK: - Steps

  /// Setup, then steps 1–8, stopping at the first failure. Cleanup is `cleanUp()`.
  func runSteps() async {
    guard await setUpRun() else { return }
    guard await step(1, "create session", { try await self.createSession() }),
      await step(2, "client identified", { try await self.firstClient() }),
      await step(3, "no client, a stale attach refused", { try await self.noMatch() }),
      await step(4, "second client told apart", { try await self.secondClient() }),
      await step(5, "two candidates refused", { try await self.twoCandidates() }),
      await step(6, "detach one identified client", { try await self.detachFirst() }),
      await step(7, "move here (attach-session -d)", { try await self.moveHere() }),
      await step(8, "detach the moved client", { try await self.detachMoved() })
    else { return }
  } // End of func runSteps()

  /// Runs one step and prints its PASS or FAIL line, then its note lines. Returns whether it
  /// passed.
  private func step(
    _ number: Int,
    _ title: String,
    _ body: () async throws -> String
  ) async -> Bool {
    let start = ContinuousClock.now
    lines.removeAll()
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
        + "(\(milliseconds(ContinuousClock.now - start)) ms): \(detail)")
    for line in lines { output("  \(line)") }
    if passed { passedCount += 1 }
    return passed
  } // End of func step(_:_:_:)

  /// Adds a note line to the current step.
  private func note(_ text: String) {
    lines.append("note: \(text)")
  }

  /// Checks that tmux answers (remotely over BatchMode ssh).
  private func setUpRun() async -> Bool {
    guard tmuxVersion != nil else {
      output(
        "FAIL setup: tmux -V did not answer \(tmux.location)"
          + (tmux.isLocal ? "" : " over ssh (BatchMode); check key authentication"))
      return false
    }
    setUp = true
    return true
  }

  /// Step 1: the session, one window running `sleep 600`.
  private func createSession() async throws -> String {
    creationStartedAt = Int64(Date().timeIntervalSince1970)
    let made = try await tmux.run([
      "new-session", "-d", "-P", "-F", CreatedSession.format, "-s", sessionName, "sleep", "600",
    ])
    guard made.succeeded, made.lines.count == 1, let record = CreatedSession.parse(made.lines[0]),
      record.name == sessionName
    else {
      created = await recoverCreatedSession()
      throw StepFailure("new-session failed: \(made.standardError.prefix(200))")
    }
    created = record
    return "\(record.sessionID) created, one window running sleep 600"
  } // End of func createSession()

  /// The session step 1 tried to create, found by its exact generated name among the sessions
  /// created since `new-session` started, or `nil`.
  private func recoverCreatedSession() async -> CreatedSession? {
    guard let started = creationStartedAt,
      let listing = try? await tmux.run(["list-sessions", "-F", CreatedSession.format]),
      listing.succeeded
    else { return nil }
    let margin: Int64 = tmux.isLocal ? 2 : 120
    return CreatedSession.find(
      named: sessionName, createdNoEarlierThan: started - margin, in: listing.lines)
  } // End of func recoverCreatedSession()

  /// Step 2: client A attaches and is the one client its reading confirms.
  private func firstClient() async throws -> String {
    let started = ContinuousClock.now
    let first = try startClient("A")
    let client = try await waitUntilConfirmed(first, clientCount: 1)
    let elapsed = milliseconds(ContinuousClock.now - started)
    if tmux.isLocal {
      guard client.processID == first.child.processID else {
        throw StepFailure("the confirmed client's pid is not the child's")
      }
      note(
        "the child's controlling terminal: \(await controllingTerminal(of: first.child)) "
          + "(its terminal \(first.terminal.path))")
    }
    note("tmux sees client A as \(await clientShape(client))")
    note("readings took \(readingSummary())")
    return "client A (\(client.name), pid \(client.processID)) confirmed by "
      + "\(evidenceName(first.evidence)) \(elapsed) ms after it was started; the session's only "
      + "client"
  } // End of func firstClient()

  /// Step 3: a terminal with no client, or a token no client carries, matches none; a stale
  /// attach there (client S) exits 65 and attaches nothing.
  private func noMatch() async throws -> String {
    let evidence: Evidence
    var unused: ProofTerminal?
    var token: LaunchToken?
    if tmux.isLocal {
      let terminal = try openTerminal()
      unused = terminal
      evidence = .terminal(terminal.path)
    } else {
      let fresh = LaunchToken()
      token = fresh
      evidence = .token(fresh)
    }
    let reading = try await read(evidence)
    guard reading.outcome == .none else {
      throw StepFailure("the reading found \(reading.candidates.count) candidate(s)")
    }
    guard reading.clients.count == 1 else {
      throw StepFailure("the session has \(reading.clients.count) clients, not 1")
    }
    let stale = try startClient("S", terminal: unused, token: token, stale: true)
    let refusedAfter = try await waitForRefusal(stale)
    let after = try await read(evidence)
    guard after.outcome == .none, after.clients.count == 1 else {
      throw StepFailure("after the stale attach: \(describe(after))")
    }
    return "\(evidenceName(evidence)) matched none of the session's 1 client; a stale attach "
      + "there (the server's start time 1 s off) exited 65 after \(refusedAfter) ms "
      + "(\(tmux.isLocal ? "the bound attach" : "the guard") refused), attaching nothing"
  } // End of func noMatch()

  /// Step 4: client B attaches; each reading confirms its own client.
  private func secondClient() async throws -> String {
    guard let first = clientLabeled("A"), let firstClient = identified[first.label] else {
      throw StepFailure("no client A")
    }
    let second = try startClient("B")
    let client = try await waitUntilConfirmed(second, clientCount: 2)
    if tmux.isLocal, client.processID != second.child.processID {
      throw StepFailure("the confirmed client's pid is not B's child's")
    }
    let again = try await read(first.evidence)
    guard again.outcome == .confirmed(firstClient), again.clients.count == 2 else {
      throw StepFailure("A's reading now: \(describe(again))")
    }
    guard client != firstClient else { throw StepFailure("A and B were read as the same client") }
    return "B (\(client.name), pid \(client.processID)) and A each confirmed by their own "
      + "\(tmux.isLocal ? "terminal" : "token") among the session's 2 clients"
  } // End of func secondClient()

  /// Step 5: client A2 carries A's evidence; A's reading refuses two candidates (and locally,
  /// where A2 shares A's client name, the bound detach of A detaches nothing), then confirms A
  /// again once A2 is ended.
  private func twoCandidates() async throws -> String {
    guard let first = clientLabeled("A"), let firstClient = identified[first.label] else {
      throw StepFailure("no client A")
    }
    let twin = try startClient(
      "A2", terminal: tmux.isLocal ? first.terminal : nil, token: first.token)
    let budget = tmux.isLocal ? Self.localAttachBudget : Self.remoteAttachBudget
    let both = try await waitForReading(first.evidence, within: budget) {
      $0.clients.count == 3 && $0.candidates.count == 2
    }
    guard case .ambiguous(let candidates) = both.outcome, candidates.count == 2,
      candidates.contains(firstClient)
    else {
      throw StepFailure("A's reading with A2 attached: \(describe(both))")
    }
    if tmux.isLocal {
      // A2 has A's terminal, so A's client name too: the bound detach must refuse.
      let (outcome, took) = try await boundDetach(firstClient)
      guard outcome == .notThisClient else {
        throw StepFailure("the bound detach of A while A2 shares its name: \(outcome.rawValue)")
      }
      let still = try await read(first.evidence)
      guard still.clients.count == 3, still.candidates.count == 2, twin.child.isRunning,
        first.child.isRunning
      else {
        throw StepFailure("after the refused detach: \(describe(still))")
      }
      note(
        "the bound detach of A (\(firstClient.name)) while A2 shares that name detached nothing "
          + "(\(took) ms); all 3 clients stay")
    }
    let ended = await twin.child.stop()
    let back = try await waitForReading(first.evidence, within: Self.leaveBudget) {
      $0.clients.count == 2 && $0.outcome == .confirmed(firstClient)
    }
    guard back.outcome == .confirmed(firstClient), back.clients.count == 2 else {
      throw StepFailure("after A2 was ended, A's reading: \(describe(back))")
    }
    note("A2 ended by SIGTERM to its group: \(ended.map { "\($0)" } ?? "not reaped")")
    return "with A2 on \(tmux.isLocal ? "A's terminal" : "A's token") A's reading found 2 "
      + "candidates among 3 clients and confirmed none; with A2 ended it confirmed A again"
  } // End of func twoCandidates()

  /// Step 6: a stale bound detach of A detaches nothing; the bound detach of A ends only A.
  private func detachFirst() async throws -> String {
    guard let first = clientLabeled("A"), let second = clientLabeled("B"),
      let firstClient = identified["A"], let secondClient = identified["B"]
    else { throw StepFailure("no clients A and B") }
    guard
      let stale = OtherClient(
        processID: String(firstClient.processID), created: String(firstClient.created + 1),
        name: firstClient.name)
    else { throw StepFailure("A's stale identity is not a client's") }
    let (outcome, staleTook) = try await boundDetach(stale)
    guard outcome == .notThisClient else {
      throw StepFailure("the stale bound detach of A: \(outcome.rawValue)")
    }
    let both = try await read(first.evidence)
    guard both.outcome == .confirmed(firstClient), both.clients.count == 2,
      first.child.isRunning, second.child.isRunning
    else {
      throw StepFailure("after the stale detach, A's reading: \(describe(both))")
    }
    note(
      "the bound detach of A with its creation time 1 s off detached nothing (\(staleTook) ms); "
        + "A and B stay")
    let took = try await detach(firstClient)
    let ended = await first.child.waitForExit(within: Self.exitBudget)
    guard ended == .exited(0) else {
      throw StepFailure("A's child did not exit 0 within \(Self.exitBudget): \(describe(ended))")
    }
    guard second.child.isRunning else { throw StepFailure("B's child ended too") }
    let reading = try await read(second.evidence)
    guard reading.outcome == .confirmed(secondClient), reading.clients.count == 1 else {
      throw StepFailure("B's reading after the detach: \(describe(reading))")
    }
    return "the bound detach of \(firstClient.name) (one tmux command) took \(took) ms; A's "
      + "child exited 0 by itself, B still attached (the session's only client) and its child "
      + "running"
  } // End of func detachFirst()

  /// Step 7: a stale move here (client M0) exits 65 and detaches nobody; client M attaches
  /// with the bound `attach-session -d`, and tmux detaches B.
  private func moveHere() async throws -> String {
    guard let second = clientLabeled("B"), let secondClient = identified["B"] else {
      throw StepFailure("no client B")
    }
    let stale = try startClient("M0", detachingOthers: true, stale: true)
    let refusedAfter = try await waitForRefusal(stale)
    let kept = try await read(second.evidence)
    guard kept.outcome == .confirmed(secondClient), kept.clients.count == 1,
      second.child.isRunning
    else {
      throw StepFailure("after the stale move here, B's reading: \(describe(kept))")
    }
    note(
      "a move here with the server's start time 1 s off exited 65 after \(refusedAfter) ms; "
        + "B stays attached")
    let started = ContinuousClock.now
    let moved = try startClient("M", detachingOthers: true)
    let client = try await waitUntilConfirmed(moved, clientCount: 1)
    let confirmedAfter = milliseconds(ContinuousClock.now - started)
    if tmux.isLocal, client.processID != moved.child.processID {
      throw StepFailure("the confirmed client's pid is not M's child's")
    }
    let ended = await second.child.waitForExit(within: Self.exitBudget)
    guard ended == .exited(0) else {
      throw StepFailure("B's child did not exit 0 within \(Self.exitBudget): \(describe(ended))")
    }
    guard moved.child.isRunning else { throw StepFailure("M's child ended") }
    return "M (\(client.name)) confirmed as the session's only client \(confirmedAfter) ms after "
      + "it was started; B's child exited 0 by itself (detached by tmux)"
  } // End of func moveHere()

  /// Step 8: the targeted detach of M; the session stays with no client.
  private func detachMoved() async throws -> String {
    guard let moved = clientLabeled("M"), let client = identified["M"] else {
      throw StepFailure("no client M")
    }
    let took = try await detach(client)
    let ended = await moved.child.waitForExit(within: Self.exitBudget)
    guard ended == .exited(0) else {
      throw StepFailure("M's child did not exit 0 within \(Self.exitBudget): \(describe(ended))")
    }
    let reading = try await read(moved.evidence)
    guard reading.clients.isEmpty, reading.outcome == .none else {
      throw StepFailure("after the detach: \(describe(reading))")
    }
    let names = try await tmux.run(["list-sessions", "-F", "#{session_name}"])
    guard names.succeeded, names.lines.contains(sessionName) else {
      throw StepFailure("the session did not survive the detach")
    }
    note("readings took \(readingSummary())")
    return "the bound detach of \(client.name) took \(took) ms; M's child exited 0 by itself; "
      + "the session alive with no client"
  } // End of func detachMoved()

  // MARK: - Clients and readings

  /// Opens a pseudo-terminal and records it for cleanup.
  private func openTerminal() throws -> ProofTerminal {
    let terminal = try ProofTerminal.open()
    terminals.append(terminal)
    return terminal
  }

  /// The client the run last started as `label`, or `nil`.
  private func clientLabeled(_ label: String) -> Client? {
    clients.last { $0.label == label }
  }

  /// The identity step 1 recorded, as bound commands require it: only the run's own
  /// `muxfinder-test-*` session, with every field (`BoundSessionIdentity.init(_:)`). With
  /// `stale`, the server's start time is one second earlier, as a restarted server's session
  /// with the same id and name would differ.
  private func boundIdentity(stale: Bool = false) throws -> BoundSessionIdentity {
    guard let created, created.name == sessionName, sessionName.hasPrefix("muxfinder-test-")
    else { throw StepFailure("no test session") }
    var identity = BoundSessionIdentity(created)
    if stale { identity.serverStartTime -= 1 }
    return identity
  } // End of func boundIdentity(stale:)

  /// Starts the plain client `label` on `terminal` (a new pseudo-terminal when `nil`) with
  /// `token` (a new one when `nil`): the local bound attach child, or ssh running the remote
  /// script. With `stale`, the identity it carries is `boundIdentity(stale: true)`'s, so it
  /// must attach nothing and exit 65 (`waitForRefusal(_:)`).
  private func startClient(
    _ label: String,
    terminal: ProofTerminal? = nil,
    token: LaunchToken? = nil,
    detachingOthers: Bool = false,
    stale: Bool = false
  ) throws -> Client {
    let identity = try boundIdentity(stale: stale)
    let token = token ?? LaunchToken()
    let command: HarnessCommand
    if let localTmux {
      guard
        let arguments = PlainLaunch.localAttachArguments(
          session: identity, detachingOthers: detachingOthers)
      else { throw StepFailure("the session's identity cannot be written as a tmux format") }
      command = HarnessCommand(
        executable: localTmux.path, arguments: arguments, environment: environment)
    } else if let remoteTmux {
      let check = [
        "", identity.sessionID.rawValue, String(identity.serverPID),
        String(identity.serverStartTime), String(identity.createdAt),
      ]
      command = HarnessCommand(
        executable: DiscoveryProbe.sshURL.path(percentEncoded: false),
        arguments: DiscoveryProbe.sshOptions
          + ["-o", "ControlMaster=no", "-o", "ControlPath=none", "-t", "--"]
          + [
            remoteTmux.destination,
            PlainLaunch.remoteCommand(
              checkArguments: check, token: token, detachingOthers: detachingOthers),
          ],
        environment: environment)
    } else {
      throw StepFailure("no tmux")
    }
    let host = try terminal ?? openTerminal()
    let child = try ProofChild.start(command, on: host)
    let evidence: Evidence = tmux.isLocal ? .terminal(host.path) : .token(token)
    let client = Client(
      label: label, token: token, terminal: host, child: child, evidence: evidence)
    clients.append(client)
    return client
  } // End of func startClient(_:terminal:token:detachingOthers:stale:)

  /// Waits for the child of `client`, started with a stale identity, to exit by itself with
  /// `PlainLaunch.sessionChangedStatus` (65: locally the bound attach refused, remotely the
  /// guard did) within the attach budget. Returns how long that took, in milliseconds.
  private func waitForRefusal(_ client: Client) async throws -> Int {
    let started = ContinuousClock.now
    let budget = tmux.isLocal ? Self.localAttachBudget : Self.remoteAttachBudget
    let ended = await client.child.waitForExit(within: budget)
    guard ended == .exited(PlainLaunch.sessionChangedStatus) else {
      throw StepFailure(
        "\(client.label)'s child did not exit \(PlainLaunch.sessionChangedStatus) within "
          + "\(budget): \(describe(ended))")
    }
    return milliseconds(ContinuousClock.now - started)
  } // End of func waitForRefusal(_:)

  /// Waits until `client`'s reading confirms one client among `clientCount`, records it as
  /// the client's tmux client and returns it.
  private func waitUntilConfirmed(_ client: Client, clientCount: Int) async throws -> OtherClient {
    let budget = tmux.isLocal ? Self.localAttachBudget : Self.remoteAttachBudget
    let reading = try await waitForReading(client.evidence, within: budget) {
      if case .confirmed = $0.outcome { return $0.clients.count == clientCount }
      return false
    }
    guard case .confirmed(let found) = reading.outcome, reading.clients.count == clientCount else {
      let exited = client.child.isRunning ? "" : "; its child exited (\(describe(client.child)))"
      throw StepFailure(
        "\(client.label) was not confirmed within \(budget): \(describe(reading))\(exited)")
    }
    identified[client.label] = found
    return found
  } // End of func waitUntilConfirmed(_:clientCount:)

  /// Reads until `done` holds or `time` passes; returns the last reading.
  private func waitForReading(
    _ evidence: Evidence,
    within time: Duration,
    until done: (PlainClientIdentification.Reading) -> Bool
  ) async throws -> PlainClientIdentification.Reading {
    let deadline = ContinuousClock.now + time
    while true {
      let reading = try await read(evidence)
      if done(reading) || ContinuousClock.now >= deadline { return reading }
      try await Task.sleep(for: Self.pollInterval)
    }
  } // End of func waitForReading(_:within:until:)

  /// One reading of the session's clients for `evidence`. Throws when tmux (or ssh) fails or
  /// the answer is unreadable.
  private func read(_ evidence: Evidence) async throws -> PlainClientIdentification.Reading {
    guard let created else { throw StepFailure("no test session") }
    let start = ContinuousClock.now
    let reading: PlainClientIdentification.Reading?
    switch evidence {
    case .terminal(let path):
      let listing = try await tmux.run([
        "list-clients", "-F", PlainClientIdentification.localFormat,
      ])
      guard listing.succeeded else {
        throw StepFailure("list-clients failed: \(listing.standardError.prefix(200))")
      }
      reading = PlainClientIdentification.local(
        listing: listing.standardOutput, sessionID: created.sessionID, terminal: path)
    case .token(let token):
      guard let remoteTmux else { throw StepFailure("no remote host") }
      let answer = try await remoteTmux.runScript(
        PlainClientIdentification.remoteScript,
        arguments: PlainClientIdentification.remoteArguments(
          tmuxPathOverride: nil, sessionID: created.sessionID, token: token))
      guard answer.succeeded else {
        throw StepFailure(
          "the remote reading failed (status \(answer.status.map(String.init) ?? "signal"))")
      }
      reading = PlainClientIdentification.remote(output: answer.standardOutput)
    }
    readingTimes.append(milliseconds(ContinuousClock.now - start))
    guard let reading else { throw StepFailure("the reading was unreadable") }
    return reading
  } // End of func read(_:)

  /// The bound detach of `client` from the run's own session (`PlainClientDetach`, PLAN.md
  /// D38): one tmux command (one ssh call remotely) in which the server checks the session's
  /// identity and exactly one client of that name with that pid and creation time in it, and
  /// only then detaches it. Returns its outcome (`detached` or `notThisClient`) and how long
  /// it took, in milliseconds; throws when it cannot be built or its answer is `failed`.
  private func boundDetach(_ client: OtherClient) async throws -> (
    outcome: PlainClientDetach.Outcome, took: Int
  ) {
    guard let arguments = PlainClientDetach.arguments(of: client, in: try boundIdentity())
    else { throw StepFailure("the bound detach of \(client.name) cannot be written") }
    let start = ContinuousClock.now
    let result = try await tmux.run(arguments)
    let took = milliseconds(ContinuousClock.now - start)
    let outcome = PlainClientDetach.outcome(
      exitStatus: result.status, standardOutput: result.standardOutput,
      standardError: result.standardError)
    guard outcome != .failed else {
      throw StepFailure(
        "the bound detach failed (status \(result.status.map(String.init) ?? "signal")): "
          + "\(result.standardError.prefix(200))")
    }
    return (outcome, took)
  } // End of func boundDetach(_:)

  /// The bound detach of `client`, which must detach it (`detached`); `notThisClient` means
  /// its identity changed and nothing was detached, a failure here. Returns how long it took,
  /// in milliseconds.
  private func detach(_ client: OtherClient) async throws -> Int {
    let (outcome, took) = try await boundDetach(client)
    guard outcome == .detached else {
      throw StepFailure("the bound detach found \(client.name) changed; nothing was detached")
    }
    return took
  } // End of func detach(_:)

  /// The child's controlling terminal as `ps -o tty=` shows it (read-only), or `?`.
  private func controllingTerminal(of child: ProofChild) async -> String {
    let request = ProcessRequest(
      executableURL: URL(fileURLWithPath: "/bin/ps"),
      arguments: ["-o", "tty=", "-p", String(child.processID)], environment: environment,
      timeout: .seconds(5))
    guard let result = try? await PosixSpawnProcessRunner().run(request), result.exitCode == 0
    else { return "?" }
    let text = String(decoding: result.standardOutput, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? "?" : text
  } // End of func controllingTerminal(of:)

  /// How tmux sees `client`: its terminal type, size and whether it is a control client
  /// (`#{client_termname}`, `#{client_width}`, `#{client_height}`, `#{client_control_mode}`),
  /// or `?` when the listing does not show it.
  private func clientShape(_ client: OtherClient) async -> String {
    let format =
      "#{client_name} #{client_termname} #{client_width}x#{client_height} "
      + "control #{client_control_mode} flags #{client_flags}"
    guard let listing = try? await tmux.run(["list-clients", "-F", format]), listing.succeeded,
      let line = listing.lines.first(where: { $0.hasPrefix(client.name + " ") })
    else { return "?" }
    return String(line.dropFirst(client.name.count + 1))
  } // End of func clientShape(_:)

  /// The readings' durations so far: count, median and maximum.
  private func readingSummary() -> String {
    let sorted = readingTimes.sorted()
    guard let last = sorted.last else { return "none" }
    return "\(sorted.count) readings, median \(sorted[sorted.count / 2]) ms, max \(last) ms"
  }

  /// `client_tty` or the token, for the output.
  private func evidenceName(_ evidence: Evidence) -> String {
    switch evidence {
    case .terminal: return "its terminal (client_tty)"
    case .token: return "its token (its parent shell's arguments, read with ps over ssh)"
    }
  }

  /// A reading in a few words: clients, candidates and the outcome.
  private func describe(_ reading: PlainClientIdentification.Reading) -> String {
    let outcome: String
    switch reading.outcome {
    case .confirmed(let client): outcome = "confirmed \(client.name)"
    case .none: outcome = "none"
    case .ambiguous(let list): outcome = "ambiguous (\(list.count))"
    }
    return "\(reading.clients.count) client(s), \(reading.candidates.count) candidate(s), "
      + outcome
  }

  /// How a child ended, for the output.
  private func describe(_ termination: ProcessResult.Termination?) -> String {
    termination.map { "\($0)" } ?? "still running"
  }

  /// How a child ended, for the output.
  private func describe(_ child: ProofChild) -> String {
    describe(child.termination)
  }

  // MARK: - Cleanup

  /// Step 9 (see the type's documentation). Never cancels itself.
  func cleanUp() async {
    let start = ContinuousClock.now
    var actions: [String] = []
    var problems: [String] = []
    var stopped = 0
    for client in clients where client.child.termination == nil {
      let ended = await client.child.stop()
      stopped += 1
      if ended == nil { problems.append("client \(client.label)'s child could not be reaped") }
    }
    if stopped > 0 { actions.append("ended \(stopped) client child(ren)") }
    let discarded = terminals.reduce(0) { $0 + $1.discardedByteCount }
    for terminal in terminals { terminal.close() }
    if !terminals.isEmpty {
      actions.append(
        "closed \(terminals.count) pseudo-terminal(s) (\(discarded) bytes discarded: \(terminals.map { String($0.discardedByteCount) }.joined(separator: "+")))"
      )
    }
    await killTestSession(actions: &actions, problems: &problems)
    if let names = try? await tmux.run(["list-sessions", "-F", "#{session_name}"]),
      names.succeeded || names.status == 1
    {
      if names.lines.contains(sessionName) { problems.append("the test session still exists") }
    } else {
      problems.append("the sessions could not be listed")
    }
    let left = await childrenLeft()
    if !left.isEmpty { problems.append("\(left.count) child process(es) of the harness left") }
    let elapsed = milliseconds(ContinuousClock.now - start)
    let summary = actions.isEmpty ? "nothing to clean" : actions.joined(separator: ", ")
    if problems.isEmpty, setUp {
      passedCount += 1
      output(
        "PASS \(Self.stepCount) cleanup (\(elapsed) ms): \(summary); no test session and no "
          + "child process left")
    } else {
      let reason = problems.isEmpty ? "setup failed" : problems.joined(separator: "; ")
      output("FAIL \(Self.stepCount) cleanup (\(elapsed) ms): \(summary); \(reason)")
    }
  } // End of func cleanUp()

  /// Kills the test session, the one step 1 recorded or, when a signal cut `new-session`
  /// short, the one found by its exact name, only while it is still exactly that session.
  private func killTestSession(actions: inout [String], problems: inout [String]) async {
    if created == nil, let recovered = await recoverCreatedSession() {
      created = recovered
      actions.append("found the test session by its name")
    }
    guard let created, let arguments = created.killIfUnchangedArguments,
      created.name == sessionName
    else { return }
    let result = try? await tmux.run(arguments)
    let outcome = result.map {
      CreatedSession.killOutcome(
        exitStatus: $0.status, standardOutput: $0.standardOutput,
        standardError: $0.standardError)
    }
    switch outcome {
    case .killed?: actions.append("killed \(created.sessionID)")
    case .notThisSession?: actions.append("\(created.sessionID) was already gone")
    default: problems.append("kill-session failed")
    }
  } // End of func killTestSession(actions:problems:)

  /// The harness's child processes still known to the kernel, looked at for up to 2 s (a tmux
  /// or ssh call that just ended may not be reaped yet).
  private func childrenLeft() async -> [pid_t] {
    let deadline = ContinuousClock.now + .seconds(2)
    while true {
      let left = ownChildProcessIDs()
      if left.isEmpty || ContinuousClock.now >= deadline { return left }
      try? await Task.sleep(for: Self.pollInterval)
    }
  } // End of func childrenLeft()
} // End of actor PlainProofRun

extension RemoteTestTmux {
  /// Runs the static `script` on the remote host with `arguments` (PLAN.md D3: one string,
  /// every argument POSIX single-quoted) over discovery's noninteractive ssh, with the same
  /// deadline as `run(_:)`. An ssh failure is exit status 255.
  func runScript(_ script: StaticShellScript, arguments: [String]) async throws -> TestTmux.Output {
    let command = ShellQuoting.remoteCommand(script: script, args: arguments)
    let request = ProcessRequest(
      executableURL: DiscoveryProbe.sshURL,
      arguments: DiscoveryProbe.sshOptions + ["-n", "-T", "--", destination, command],
      environment: environment, timeout: DiscoveryProbe.defaultTimeout)
    let result = try await runner.run(request)
    return TestTmux.Output(
      status: result.exitCode,
      standardOutput: String(decoding: result.standardOutput, as: UTF8.self),
      standardError: String(decoding: result.standardError, as: UTF8.self),
      timedOut: result.timedOut)
  } // End of func runScript(_:arguments:)
} // End of extension RemoteTestTmux
