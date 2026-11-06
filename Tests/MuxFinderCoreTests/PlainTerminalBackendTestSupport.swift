import Foundation
import Testing
import os

@testable import MuxFinderCore

/// What one of the plain backend's process requests asks for (PLAN.md D38), told from its
/// arguments.
enum PlainRequestKind: Hashable {
  /// This Mac's confirmation reading (`list-clients -F localFormat`).
  case localListing
  /// An SSH host's token reading (`PlainClientIdentification.remoteScript`).
  case remoteReading
  /// The read-only bound presence check (`PlainClientPresence`).
  case presence
  /// The bound detach (`PlainClientDetach`).
  case detach
  /// tmux's clock and the session's clients (`PlainSessionClients`).
  case sessionClients
  /// Anything else.
  case other
}

/// A `ProcessRunner` for the plain backend's tests: it records every request and answers each
/// with what `answer` returns for the request's kind and its 1-based number among the requests
/// of that kind, after awaiting `hook` (if set) with the same values, so a test can act while
/// a request is in flight. It runs nothing.
final class ScriptedProcessRunner: ProcessRunner {
  /// Makes the answer to the `n`-th request of a kind.
  typealias Answer = @Sendable (_ kind: PlainRequestKind, _ number: Int) -> ProcessResult
  /// Runs while the `n`-th request of a kind is in flight, before its answer is made.
  typealias Hook = @Sendable (_ kind: PlainRequestKind, _ number: Int) async -> Void

  /// Mutable state.
  private struct State {
    /// Requests received so far, in order.
    var requests: [ProcessRequest] = []
    /// How many requests of each kind came so far.
    var counts: [PlainRequestKind: Int] = [:]
    /// The answer.
    var answer: Answer
    /// The hook, if any.
    var hook: Hook?
  }

  /// The state.
  private let state: OSAllocatedUnfairLock<State>

  /// A runner answering with `answer` (by default, exit 1 with no output for everything).
  init(_ answer: @escaping Answer = { _, _ in PlainBackendSupport.output("", status: 1) }) {
    state = OSAllocatedUnfairLock(initialState: State(answer: answer))
  }

  /// Changes the answer of later requests.
  func setAnswer(_ answer: @escaping Answer) {
    state.withLock { $0.answer = answer }
  }

  /// Sets (or with `nil` removes) the hook of later requests.
  func setHook(_ hook: Hook?) {
    state.withLock { $0.hook = hook }
  }

  /// Every request received so far, in order.
  var requests: [ProcessRequest] { state.withLock { $0.requests } }

  /// The requests of `kind`, in order.
  func requests(_ kind: PlainRequestKind) -> [ProcessRequest] {
    requests.filter { Self.kind(of: $0) == kind }
  }

  /// Records `request`, awaits the hook (if any), then answers it.
  func run(_ request: ProcessRequest) async throws -> ProcessResult {
    let kind = Self.kind(of: request)
    let (number, hook) = state.withLock { state -> (Int, Hook?) in
      state.requests.append(request)
      state.counts[kind, default: 0] += 1
      return (state.counts[kind] ?? 0, state.hook)
    }
    if let hook { await hook(kind, number) }
    let answer = state.withLock { $0.answer }
    return answer(kind, number)
  } // End of func run(_:)

  /// The kind of `request`, from its arguments (locally argv, remotely the D3 string).
  static func kind(of request: ProcessRequest) -> PlainRequestKind {
    let text = request.arguments.joined(separator: " ")
    let remoteReading =
      "/bin/sh -c " + ShellQuoting.posixSingleQuote(PlainClientIdentification.remoteScript.source)
    if request.arguments.last?.hasPrefix(remoteReading) == true { return .remoteReading }
    if text.contains("detach-client -t") { return .detach }
    if text.contains(PlainClientPresence.presentMarker) { return .presence }
    if text.contains("list-clients"), text.contains("%s") { return .sessionClients }
    if text.contains("list-clients") { return .localListing }
    return .other
  } // End of static func kind(of:)
} // End of class ScriptedProcessRunner

/// Synthetic values for the plain backend's tests.
enum PlainBackendSupport {
  /// A remote Mac reached with ssh.
  static let remoteHost = HostConfig(
    id: UUID(uuidString: "00000000-0000-4000-8000-0000000000c2")!, displayName: "Remote Mac",
    mode: .ssh, sshDestination: "remote-fixture")
  /// The launch's terminal on This Mac.
  static let terminalPath = "/dev/ttys004"
  /// The attach child (the local tmux client).
  static let childPID: Int32 = 5150
  /// The attach child's kernel start time.
  static let childStart = ProcessStartTime(seconds: 1_792_600_100, microseconds: 250)
  /// The client's creation time by tmux's clock.
  static let clientCreated: Int64 = 1_792_600_100

  /// The session `$3` as discovery reports it on `host`.
  static func session(on host: HostConfig = AttachTestSupport.host) -> DiscoveredSession {
    DiscoveredSession(
      key: SessionKey(
        hostID: host.id, server: AttachTestSupport.server, sessionID: TmuxSessionID("$3")!),
      name: "fixture-session", createdAt: 1_792_600_001, windowCount: 2, attachedClientCount: 0,
      lastActivityAt: 1_792_600_050, clients: [])
  }

  /// The attach target of `session(on:)`.
  static func target(on host: HostConfig = AttachTestSupport.host) -> AttachTarget {
    AttachTarget(host: host, session: session(on: host))
  }

  /// The session's identity as the plain client record holds it: all six fields, written out.
  static let identity = BoundSessionIdentity(
    sessionID: TmuxSessionID("$3")!, serverPID: 4242, serverStartTime: 1_792_599_999,
    createdAt: 1_792_600_001, socketPath: "/private/tmp/tmux-501/default", name: "fixture-session")

  /// The launch's client on This Mac.
  static let localClient = OtherClient(
    processID: "5150", created: "1792600100", name: "/dev/ttys004")!

  /// The launch's client on the remote host.
  static let remoteClient = OtherClient(
    processID: "6100", created: "1792600100", name: "/dev/ttys007")!

  /// The helper's early report for `token`.
  static func report(
    for token: LaunchToken,
    terminalPath: String? = terminalPath,
    childPID: Int32 = childPID,
    start: ProcessStartTime = childStart
  ) -> PlainLaunchReport {
    PlainLaunchReport(
      id: token, helperPID: 777, terminalPath: terminalPath, attachChildPID: childPID,
      attachChildStartTime: start)
  }

  /// The launch id of the first early report in `store`'s folder, if there is one.
  static func reportToken(in store: LaunchStore) -> LaunchToken? {
    guard
      let name = (try? LaunchTestSupport.names(in: store.directory))?
        .first(where: { $0.hasSuffix(".report.json") })
    else { return nil }
    return LaunchToken(String(name.prefix(36)))
  }

  /// The helper's result for `token`, with `failure`.
  static func result(for token: LaunchToken, failure: LaunchFailure? = nil) -> LaunchResult {
    LaunchResult(
      id: token, helperPID: 777, startedAt: ManualAttachClock.baseDate, childStartedAt: nil,
      endedAt: ManualAttachClock.baseDate,
      childTermination: .exited(failure?.exitStatus ?? 0), failure: failure)
  }

  /// A finished run with `text` on standard output.
  static func output(_ text: String, status: Int32 = 0, stderr: String = "") -> ProcessResult {
    ProcessResult(
      processID: 1, termination: .exited(status), standardOutput: Data(text.utf8),
      standardError: Data(stderr.utf8))
  }

  /// One `list-clients -F PlainClientIdentification.localFormat` line.
  static func listingLine(
    sessionID: String = "$3",
    pid: Int32 = childPID,
    created: Int64 = clientCreated,
    tty: String = terminalPath
  ) -> String {
    [sessionID, String(pid), String(created), tty, tty].joined(separator: "\t")
  }

  /// A local listing of `lines`.
  static func listing(_ lines: String...) -> ProcessResult {
    output(lines.map { $0 + "\n" }.joined())
  }

  /// The remote reading's answer for `clients` (`match` or `other`, pid, created, name).
  static func remoteAnswer(_ clients: [(match: Bool, client: OtherClient)]) -> ProcessResult {
    let lines = clients.map {
      "\($0.match ? "match" : "other") \($0.client.processID) \($0.client.created) "
        + $0.client.name
    }
    return output((lines + ["end \(clients.count)"]).map { $0 + "\n" }.joined())
  }

  /// The built-in Terminal definition, loaded as text (never compiled).
  static func terminal() throws -> LoadedTerminalDefinition {
    let definitions = TerminalDefinitionTestSupport.load(
      builtIn: TerminalDefinitionTestSupport.builtInDirectory)
    return try #require(definitions.definition(withID: "terminal"))
  }

  /// The built-in Ghostty definition, loaded as text (never compiled).
  static func ghostty() throws -> LoadedTerminalDefinition {
    let definitions = TerminalDefinitionTestSupport.load(
      builtIn: TerminalDefinitionTestSupport.builtInDirectory)
    return try #require(definitions.definition(withID: "ghostty"))
  }
} // End of enum PlainBackendSupport

/// One plain backend over test fakes: the fake window layer, a scripted process runner, a fake
/// discovery, a manual clock, an update log, and a real `LaunchStore` on a private folder
/// (removed by `cleanUp()`). By default every open plays the helper: it takes the plain request
/// (kept in `taken`, so the backend can no longer withdraw it), then writes the early report
/// `report` makes (if any) and the result `result` makes (if any).
@MainActor
final class PlainBackendHarness {
  /// The launch files.
  let store: LaunchStore
  /// The private folder holding them.
  let root: URL
  /// The window layer.
  let windows = FakePlainTerminalWindowLayer()
  /// The process runner.
  let runner: ScriptedProcessRunner
  /// Discovery.
  let discovery: FakeDiscovery
  /// The session creator.
  let creator: FakeSessionCreator
  /// The clock.
  let clock: any AttachClock
  /// The published updates.
  let log = UpdateLog()
  /// The diagnostics.
  let diagnostics = DiagnosticsLog()
  /// The backend.
  let backend: PlainTerminalBackend
  /// The loaded definition.
  let loaded: LoadedTerminalDefinition
  /// The plain requests the helper took, in order.
  private(set) var taken: [LaunchRequest] = []
  /// Whether an open takes the request (as the helper does).
  var takesRequests = true
  /// What an open writes as the helper's early report.
  var report: (@Sendable (LaunchToken) -> PlainLaunchReport?)? = {
    PlainBackendSupport.report(for: $0)
  }
  /// What an open writes as the helper's result.
  var result: (@Sendable (LaunchToken) -> LaunchResult?)?

  /// A harness for `loaded` (Terminal by default) whose discovery lists `sessions` (the
  /// fixture session on This Mac by default), whose runner answers `answer`, and whose
  /// start-time reader answers `startTime`.
  init(
    loaded: LoadedTerminalDefinition? = nil,
    sessions: [DiscoveredSession] = [PlainBackendSupport.session()],
    discovery: FakeDiscovery? = nil,
    answer: @escaping ScriptedProcessRunner.Answer = { _, _ in
      PlainBackendSupport.listing(PlainBackendSupport.listingLine())
    },
    startTime: @escaping @Sendable (Int32) -> ProcessStartTime? = { pid in
      pid == PlainBackendSupport.childPID ? PlainBackendSupport.childStart : nil
    },
    creator: FakeSessionCreator = FakeSessionCreator(.failure(.timedOut)),
    clock: any AttachClock = ManualAttachClock(),
    configuration: AttachCoordinator.Configuration = AttachCoordinator.Configuration()
  ) throws {
    // The store's clock is the test clock, so a request written after virtual time passed is
    // still fresh when the played helper takes it.
    let root = try TestSupport.makeTemporaryDirectory()
    let store = LaunchStore(directory: root.appending(path: "launch"), now: { clock.date() })
    try store.prepareDirectory()
    self.store = store
    self.root = root
    let loaded = try loaded ?? PlainBackendSupport.terminal()
    self.loaded = loaded
    runner = ScriptedProcessRunner(answer)
    self.discovery = discovery ?? FakeDiscovery(.ok(sessions))
    self.creator = creator
    self.clock = clock
    let log = self.log
    backend = PlainTerminalBackend(
      loaded: loaded, windows: windows, helperPath: AttachTestSupport.helper, store: store,
      discovery: self.discovery,
      tmux: PlainTmuxCommands(
        runner: runner, baseEnvironment: ["PATH": "/usr/bin:/bin", "TMUX": "/tmp/x,1,0"]),
      sessionCreator: creator, clock: clock, configuration: configuration,
      processStartTime: startTime, diagnostics: diagnostics, onUpdate: { log.record($0) })
    windows.onOpen = { [weak self] token in self?.playHelper(token) }
  } // End of init(loaded:sessions:discovery:answer:startTime:creator:clock:configuration:)

  /// What the helper does at an open: takes the request, writes the report and the result.
  private func playHelper(_ token: LaunchToken) {
    if takesRequests, let request = try? store.takePlainRequest(token) { taken.append(request) }
    if let report = report?(token) { try? store.writeReport(report) }
    if let result = result?(token) { try? store.writeResult(result) }
  }

  /// The files left in the launch folder, sorted.
  func files() throws -> [String] {
    try LaunchTestSupport.names(in: store.directory)
  }

  /// Removes the private folder.
  func cleanUp() {
    try? FileManager.default.removeItem(at: root)
  }
} // End of class PlainBackendHarness
