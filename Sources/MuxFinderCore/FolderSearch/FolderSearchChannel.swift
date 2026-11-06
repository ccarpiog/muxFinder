import Foundation

/// One folder search's results (PLAN.md D36). Held in memory only, never written to disk.
public struct FolderSearchAnswer: Sendable, Hashable {
  /// The folders found, at most `FolderSearchScript.resultLimit`, in Spotlight's order.
  public var paths: [String]
  /// Whether more folders matched than the answer holds.
  public var isLimited: Bool
  /// How many path records the parser left out (too long, or not UTF-8).
  public var droppedCount: Int
  /// From the query line being written to its end record.
  public var latency: Duration

  /// Creates an answer.
  public init(paths: [String], isLimited: Bool, droppedCount: Int = 0, latency: Duration = .zero) {
    self.paths = paths
    self.isLimited = isLimited
    self.droppedCount = droppedCount
    self.latency = latency
  }
}

/// What a folder search shows (PLAN.md D36): the latest text asked for, on which host and in
/// which scope, and where its search stands.
public struct FolderSearchState: Sendable, Hashable {
  /// Where the search for `text` stands.
  public enum Phase: Sendable, Hashable {
    /// Nothing is searched: no text was asked for, it is too short, or the channel was closed.
    case idle
    /// The text cannot be searched (a control character, or too long).
    case refused(FolderSearchTextIssue)
    /// Waiting for typing to pause, for the channel to open, or for the answer.
    case searching
    /// The answer for `text` and `scope`.
    case answered(FolderSearchAnswer)
    /// The host cannot search `scope` (from the header, or the script's answer); nothing was
    /// sent, or nothing more will be until the text, scope or host changes.
    case unavailable(FolderSearchUnavailable)
    /// The second failure in a row; it stands until the text, the scope or the host changes.
    case failed(FolderSearchFailure)
  }

  /// The host searched, once one was asked for.
  public var host: FolderSearchHost?
  /// The latest text asked for, as typed.
  public var text: String
  /// The scope of the latest request.
  public var scope: FolderSearchScope
  /// Where the search for `text` stands.
  public var phase: Phase
  /// The latest header from `host` (kept after a quiet close), or `nil` before one arrived.
  public var header: FolderSearchHeader?
  /// How long the latest channel took from its start to its header.
  public var openDuration: Duration?
  /// How many answers were dropped because a newer text had been asked for, or because their
  /// id was not the one waited for.
  public var droppedReplies: Int

  /// Nothing asked for yet.
  public static let initial = FolderSearchState(
    host: nil, text: "", scope: .standard, phase: .idle, header: nil, openDuration: nil,
    droppedReplies: 0)
}

/// The folder-search channel (PLAN.md D36): one long-lived script on one host at a time, fed
/// the latest typed text as the user pauses, with at most one query in flight.
///
/// - **Debounce and latest only:** `search(_:scope:on:)` runs on every edit; the query is sent
///   `Configuration.debounce` after the last call, and only for the latest text. While a query
///   is in flight nothing else is sent; an answer to an older text (or an id not waited for) is
///   dropped and counted, and the latest text is sent at once.
/// - **Opening:** the first searchable text opens the script (before its debounce, so the
///   connection is ready sooner); queries are sent only after its header. A header that says
///   the scope cannot be searched (no `mdfind`, indexing off, no home folder) is reported and
///   no query is sent.
/// - **Bounded waits:** the header within `headerTimeout` of the start (discovery's connect
///   timeout plus a margin), each answer within `answerTimeout` of its line. The script stops
///   a search itself after `FolderSearchScript.searchDeadline`, sooner, and answers `error
///   timeout`: reported as `searchTimedOut`, like a failed search, with no reopen.
/// - **Failures:** a dead process, a timeout, an open that fails or output that is not the
///   script's ends the process (standard input closed, terminated after a grace period, reaped)
///   and counts one failure; only an answer resets the count. The first failure in a row opens
///   a new process at once for the latest text (or, when nothing is pending, on the next
///   query). A failure when one came just before is reported (`failed`) and stands until the
///   text, the scope or the host changes; each change then makes one new attempt.
/// - **Closing:** a quiet `Configuration.quietPeriod` without a request closes the process
///   (not a failure); a host change closes it and starts afresh; `close()` closes everything and
///   returns once every process has been reaped. Closing standard input ends the script.
///
/// Time comes from an `AttachClock`, processes from a `FolderSearchTransport`, so tests drive
/// both. Results are kept in memory only.
public actor FolderSearchChannel {
  /// The channel's timings.
  public struct Configuration: Sendable, Hashable {
    /// How long typing must pause before a query is sent.
    public var debounce: Duration
    /// How long the script may take to write its header.
    public var headerTimeout: Duration
    /// How long one answer may take.
    public var answerTimeout: Duration
    /// How long the channel stays open without a request.
    public var quietPeriod: Duration

    /// The defaults: 150 ms, discovery's 5 s connect timeout plus 5 s, 5 s and one minute.
    public init(
      debounce: Duration = .milliseconds(150),
      headerTimeout: Duration = .seconds(10),
      answerTimeout: Duration = .seconds(5),
      quietPeriod: Duration = .seconds(60)
    ) {
      self.debounce = debounce
      self.headerTimeout = headerTimeout
      self.answerTimeout = answerTimeout
      self.quietPeriod = quietPeriod
    } // End of init(debounce:headerTimeout:answerTimeout:quietPeriod:)
  }

  /// A text and scope asked for: what a reported failure stands for.
  struct RequestKey: Sendable, Hashable {
    /// The text as typed.
    var text: String
    /// The scope.
    var scope: FolderSearchScope
  }

  /// The latest searchable request.
  struct Request: Sendable {
    /// The host.
    var host: FolderSearchHost
    /// The text and scope.
    var key: RequestKey
    /// The escaped name text.
    var name: FolderSearchNameText
    /// Its number; every `search` call that makes a request takes the next one.
    var serial: UInt64
  }

  /// The script running (or starting) now.
  struct Live {
    /// Its generation; events from any other are ignored.
    var generation: UInt64
    /// Its host.
    var host: FolderSearchHost
    /// The connection, once the open returned.
    var connection: (any FolderSearchConnection)?
    /// The header, once it arrived.
    var header: FolderSearchHeader?
    /// When the open started.
    var startedAt: ContinuousClock.Instant
    /// Fires `headerTimeout` after the start.
    var headerTimer: Task<Void, Never>?
    /// Reads the connection's events.
    var reader: Task<Void, Never>?
  }

  /// The query waiting for its answer.
  struct InFlight {
    /// Its id.
    var id: UInt64
    /// The request it asks.
    var serial: UInt64
    /// When its line was written.
    var sentAt: ContinuousClock.Instant
    /// Fires `answerTimeout` after that.
    var timer: Task<Void, Never>
  }

  /// Starts scripts.
  let transport: any FolderSearchTransport
  /// Paces the debounce and every timeout.
  let clock: any AttachClock
  /// The timings.
  public let configuration: Configuration

  /// What the search shows now.
  public private(set) var state = FolderSearchState.initial

  /// The latest searchable request, or `nil` when the latest text is not searchable.
  var request: Request?
  /// The latest request serial given out.
  var serial: UInt64 = 0
  /// The latest serial whose debounce has passed.
  var debouncedSerial: UInt64 = 0
  /// The latest serial that got its answer (or its unavailability).
  var answeredSerial: UInt64 = 0
  /// The script running now.
  var live: Live?
  /// The query in flight.
  var inFlight: InFlight?
  /// The latest generation given out.
  var generation: UInt64 = 0
  /// The next query id.
  var nextQueryID: UInt64 = 1
  /// Failures since the last answer.
  var consecutiveFailures = 0
  /// The request a reported failure stands for.
  var failedRequest: RequestKey?
  /// The pending debounce.
  var debounceTask: Task<Void, Never>?
  /// The pending quiet-period timer and its token.
  var quietTask: Task<Void, Never>?
  /// The quiet timer's current token.
  var quietToken: UInt64 = 0
  /// Opens and closes still running, by token.
  var pendingTasks: [UInt64: Task<Void, Never>] = [:]
  /// The next pending task token.
  var nextTaskToken: UInt64 = 0
  /// The state streams.
  var subscribers: [UUID: AsyncStream<FolderSearchState>.Continuation] = [:]

  /// A channel over `transport`, timed by `clock`.
  public init(
    transport: any FolderSearchTransport,
    clock: any AttachClock = SystemAttachClock(),
    configuration: Configuration = Configuration()
  ) {
    self.transport = transport
    self.clock = clock
    self.configuration = configuration
  }

  /// The state now, then after every change (the newest `bufferingNewest` kept).
  public func updates(bufferingNewest limit: Int = 1) -> AsyncStream<FolderSearchState> {
    let (stream, sink) = AsyncStream.makeStream(
      of: FolderSearchState.self, bufferingPolicy: .bufferingNewest(max(1, limit)))
    let id = UUID()
    subscribers[id] = sink
    sink.yield(state)
    sink.onTermination = { _ in Task { await self.unsubscribe(id) } }
    return stream
  } // End of func updates(bufferingNewest:)

  /// Forgets a finished stream.
  func unsubscribe(_ id: UUID) {
    subscribers[id] = nil
  }

  /// Tells every stream the state.
  func publish() {
    for sink in subscribers.values { sink.yield(state) }
  }

  // MARK: - Requests

  /// Searches folder names containing `text` in `scope` on `host`: called on every edit (and
  /// whenever the scope or host changes). Text that is too short leaves the search idle; text
  /// that cannot be searched is refused; anything else is sent after the debounce.
  public func search(_ text: String, scope: FolderSearchScope, on host: FolderSearchHost) {
    restartQuietTimer()
    if state.host != host { switchHost(to: host) }
    state.text = text
    state.scope = scope
    let key = RequestKey(text: text, scope: scope)
    let name: FolderSearchNameText
    do throws(FolderSearchTextIssue) {
      name = try FolderSearchText.nameText(for: text)
    } catch {
      request = nil
      debounceTask?.cancel()
      failedRequest = nil
      state.phase = error == .tooShort ? .idle : .refused(error)
      publish()
      return
    }
    if let request, request.key == key, inFlight?.serial == request.serial { return }
    if let failedRequest, failedRequest == key, case .failed = state.phase { return }
    failedRequest = nil
    serial += 1
    request = Request(host: host, key: key, name: name, serial: serial)
    if let header = live?.header, let reason = header.unavailability(for: scope) {
      answeredSerial = serial
      state.phase = .unavailable(reason)
      publish()
      return
    }
    state.phase = .searching
    publish()
    if live == nil { startOpening() }
    debounceTask?.cancel()
    let mine = serial
    let clock = clock
    let delay = configuration.debounce
    debounceTask = Task {
      do {
        try await clock.sleep(for: delay)
      } catch {
        return
      }
      self.debouncePassed(mine)
    }
  } // End of func search(_:scope:on:)

  /// Starts afresh for `host`: closes the script, forgets its failures and header.
  func switchHost(to host: FolderSearchHost) {
    closeLive()
    consecutiveFailures = 0
    failedRequest = nil
    request = nil
    state.host = host
    state.header = nil
    state.openDuration = nil
  }

  /// The debounce of request `mine` passed.
  func debouncePassed(_ mine: UInt64) {
    guard mine == serial else { return }
    debouncedSerial = mine
    pump()
  }

  /// Sends the latest request when it is due: debounced, not answered, no query in flight, the
  /// header in; opens the script when none runs.
  func pump() {
    guard let request, request.serial != answeredSerial, failedRequest == nil else { return }
    guard inFlight == nil else { return }
    guard let live else {
      startOpening()
      return
    }
    guard let connection = live.connection, let header = live.header else { return }
    if let reason = header.unavailability(for: request.key.scope) {
      answeredSerial = request.serial
      state.phase = .unavailable(reason)
      publish()
      return
    }
    guard request.serial == debouncedSerial else { return }
    let id = nextQueryID
    nextQueryID += 1
    let line = FolderSearchScript.queryLine(id: id, scope: request.key.scope, name: request.name)
    guard connection.send(line) else {
      fail(live.generation, .ended(nil))
      return
    }
    let generation = live.generation
    let clock = clock
    let limit = configuration.answerTimeout
    let timer = Task {
      do {
        try await clock.sleep(for: limit)
      } catch {
        return
      }
      self.answerTimedOut(generation, id: id)
    }
    inFlight = InFlight(id: id, serial: request.serial, sentAt: clock.now(), timer: timer)
  } // End of func pump()

  // MARK: - The process

  /// Starts a script for the current host.
  func startOpening() {
    guard let host = state.host else { return }
    generation += 1
    let mine = generation
    let clock = clock
    let limit = configuration.headerTimeout
    let timer = Task {
      do {
        try await clock.sleep(for: limit)
      } catch {
        return
      }
      self.headerTimedOut(mine)
    }
    live = Live(generation: mine, host: host, startedAt: clock.now(), headerTimer: timer)
    let transport = transport
    track { () async in
      do throws(FolderSearchFailure) {
        let connection = try await transport.open(host)
        await self.opened(mine, connection)
      } catch {
        await self.fail(mine, error)
      }
    }
  } // End of func startOpening()

  /// The open of generation `mine` returned `connection`: reads its events, or closes it when
  /// that generation is over.
  func opened(_ mine: UInt64, _ connection: any FolderSearchConnection) {
    guard var live, live.generation == mine, live.connection == nil else {
      closeConnection(connection)
      return
    }
    live.connection = connection
    live.reader = Task {
      for await event in connection.events {
        self.handle(event, from: mine)
      } // End of loop over the connection's events
    }
    self.live = live
  } // End of func opened(_:_:)

  /// Handles one event of generation `mine`.
  func handle(_ event: FolderSearchConnectionEvent, from mine: UInt64) {
    guard var live, live.generation == mine else { return }
    switch event {
    case .header(let header):
      guard live.header == nil else {
        fail(mine, .protocolError(.badHeader))
        return
      }
      live.header = header
      live.headerTimer?.cancel()
      live.headerTimer = nil
      self.live = live
      state.header = header
      state.openDuration = live.startedAt.duration(to: clock.now())
      publish()
      pump()
    case .reply(let reply):
      received(reply)
    case .protocolError(let error):
      fail(mine, .protocolError(error))
    case .ended(let end):
      if case .ssh = live.host, end.termination == .exited(ErrorClassifier.sshErrorExitStatus) {
        fail(mine, .connection(ErrorClassifier.sshFailureStatus(stderr: end.standardError)))
      } else {
        fail(mine, .ended(end.termination))
      }
    }
  } // End of func handle(_:from:)

  /// Handles an answer from the running script.
  func received(_ reply: FolderSearchReply) {
    guard let current = inFlight, reply.id == current.id else {
      state.droppedReplies += 1
      publish()
      return
    }
    current.timer.cancel()
    inFlight = nil
    consecutiveFailures = 0
    restartQuietTimer()
    guard let request, request.serial == current.serial else {
      state.droppedReplies += 1
      publish()
      pump()
      return
    }
    answeredSerial = request.serial
    let latency = current.sentAt.duration(to: clock.now())
    switch reply.status {
    case .ok, .limited:
      state.phase = .answered(
        FolderSearchAnswer(
          paths: reply.paths, isLimited: reply.status == .limited,
          droppedCount: reply.droppedCount, latency: latency))
    case .error("unavailable"):
      state.phase = .unavailable(.noSpotlight)
    case .error("home"):
      state.phase = .unavailable(.noHomeFolder)
    case .error("search"):
      failedRequest = request.key
      state.phase = .failed(.searchFailed)
    case .error("timeout"):
      failedRequest = request.key
      state.phase = .failed(.searchTimedOut)
    case .error(let code):
      failedRequest = request.key
      state.phase = .failed(.queryRefused(code))
    }
    publish()
  } // End of func received(_:)

  /// The header of generation `mine` did not arrive in time.
  func headerTimedOut(_ mine: UInt64) {
    guard let live, live.generation == mine, live.header == nil else { return }
    fail(mine, .headerTimedOut)
  }

  /// Query `id` of generation `mine` got no answer in time.
  func answerTimedOut(_ mine: UInt64, id: UInt64) {
    guard let live, live.generation == mine, inFlight?.id == id else { return }
    fail(mine, .answerTimedOut)
  }

  /// Generation `mine` failed with `failure`: ends it, counts the failure, and opens again for
  /// the latest request (the first failure in a row) or reports it.
  func fail(_ mine: UInt64, _ failure: FolderSearchFailure) {
    guard let live, live.generation == mine else { return }
    closeLive()
    consecutiveFailures += 1
    guard let request, request.serial != answeredSerial else { return }
    if consecutiveFailures >= 2 {
      failedRequest = request.key
      answeredSerial = request.serial
      state.phase = .failed(failure)
      publish()
    } else {
      pump()
    }
  } // End of func fail(_:_:)

  /// Ends the running script, if any: its timers, the query in flight, and the process (closed
  /// in the background; `close()` waits for it). Later events of its generation are ignored.
  func closeLive() {
    guard let live else { return }
    self.live = nil
    live.headerTimer?.cancel()
    inFlight?.timer.cancel()
    inFlight = nil
    if let connection = live.connection { closeConnection(connection) }
  }

  /// Closes `connection` in the background, tracked until it is reaped.
  func closeConnection(_ connection: any FolderSearchConnection) {
    track { () async in await connection.close() }
  }

  /// Runs `work` as a tracked task, so `close()` can wait for it.
  func track(_ work: @escaping @Sendable () async -> Void) {
    nextTaskToken += 1
    let token = nextTaskToken
    pendingTasks[token] = Task {
      await work()
      self.finished(token)
    }
  }

  /// Forgets a tracked task that ended.
  func finished(_ token: UInt64) {
    pendingTasks[token] = nil
  }

  // MARK: - Closing

  /// Restarts the quiet-period timer.
  func restartQuietTimer() {
    quietTask?.cancel()
    quietToken += 1
    let token = quietToken
    let clock = clock
    let period = configuration.quietPeriod
    quietTask = Task {
      do {
        try await clock.sleep(for: period)
      } catch {
        return
      }
      self.quietPeriodPassed(token)
    }
  } // End of func restartQuietTimer()

  /// The quiet period passed: closes the script unless a query is in flight.
  func quietPeriodPassed(_ token: UInt64) {
    guard token == quietToken else { return }
    if inFlight != nil {
      restartQuietTimer()
      return
    }
    closeLive()
  }

  /// Closes the channel: no timer, no request, no script; the state goes back to idle. Returns
  /// once every script it started has been reaped. A later `search` opens a new one.
  public func close() async {
    debounceTask?.cancel()
    debounceTask = nil
    quietTask?.cancel()
    quietTask = nil
    closeLive()
    request = nil
    failedRequest = nil
    consecutiveFailures = 0
    state = FolderSearchState.initial
    publish()
    // An open still running closes its connection as it returns (`opened(_:_:)`), which adds
    // a close to wait for.
    while let task = pendingTasks.values.first {
      await task.value
    } // End of loop over pending opens and closes
  } // End of func close()

  /// How many opens and closes are still running (tests).
  public var pendingTaskCount: Int { pendingTasks.count }
}
