import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// The bound plain commands (PLAN.md D38): an attach and a detach that tmux checks and carries
/// out in one command, so neither reaches a session that took the recorded one's id (a
/// restarted server) or a client that took the recorded one's terminal. The text of both, the
/// detach's outcome, and on a private server what each does with every field off by one.
@Suite("Plain bound commands")
struct PlainBoundCommandsTests {
  /// The server of the fixtures.
  static let server = ServerIdentity(
    socketPath: "/private/tmp/tmux-501/default", pid: 4242, startTime: 1_792_599_999)
  /// The recorded session of the fixtures.
  static let record = CreatedSession(
    server: server, sessionID: TmuxSessionID("$3")!, createdAt: 1_792_600_001,
    name: "muxfinder-test-0a1b2c3d")
  /// The guard's four values only, as a launch request carries them.
  static let fourFields = BoundSessionIdentity(
    sessionID: TmuxSessionID("$3")!, serverPID: 4242, serverStartTime: 1_792_599_999,
    createdAt: 1_792_600_001)
  /// The session part of the conditions, all six fields.
  static let sessionCondition =
    "#{&&:#{==:#{session_id},$3},#{&&:#{==:#{session_created},1792600001},"
    + "#{&&:#{==:#{pid},4242},#{&&:#{==:#{start_time},1792599999},"
    + "#{&&:#{==:#{socket_path},/private/tmp/tmux-501/default},"
    + "#{==:#{session_name},muxfinder-test-0a1b2c3d}}}}}}"
  /// A client of the fixtures.
  static let client = OtherClient(processID: "5150", created: "1792600100", name: "/dev/ttys004")!

  // MARK: - Text

  /// The condition compares every field given, the socket path and name as format literals;
  /// with the guard's four values only, just those four.
  @Test func writesTheCondition() {
    #expect(BoundSessionIdentity(Self.record).condition == Self.sessionCondition)
    #expect(
      Self.fourFields.condition
        == "#{&&:#{==:#{session_id},$3},#{&&:#{==:#{session_created},1792600001},"
        + "#{&&:#{==:#{pid},4242},#{==:#{start_time},1792599999}}}}")
    var odd = BoundSessionIdentity(Self.record)
    odd.name = "muxfinder-test-a #ü, x} 日本;"
    #expect(
      odd.condition?.hasSuffix("#{==:#{session_name},muxfinder-test-a ##ü#, x#} 日本;}}}}}}")
        == true)
  } // End of func writesTheCondition()

  /// A value that cannot be written as a format literal, or a number out of range, gives no
  /// condition, so no bound command at all.
  @Test func refusesValuesItCannotEncode() {
    var identity = BoundSessionIdentity(Self.record)
    for name in ["", "a{b", "a[b", "#[fg=red]", "a\tb"] {
      identity.name = name
      #expect(identity.condition == nil, "\(name)")
      #expect(PlainLaunch.localAttachArguments(session: identity, detachingOthers: false) == nil)
      #expect(PlainClientDetach.arguments(of: Self.client, in: identity) == nil)
    } // End of loop over the names
    identity = BoundSessionIdentity(Self.record)
    identity.socketPath = "/tmp/{x}/default"
    #expect(identity.condition == nil)
    for change in [
      { (value: inout BoundSessionIdentity) in value.serverPID = 0 },
      { (value: inout BoundSessionIdentity) in value.serverStartTime = -1 },
      { (value: inout BoundSessionIdentity) in value.createdAt = -1 },
    ] {
      identity = BoundSessionIdentity(Self.record)
      change(&identity)
      #expect(identity.condition == nil)
    } // End of loop over the numbers out of range
  } // End of func refusesValuesItCannotEncode()

  /// The local attach is one `if-shell -F` on the session's id: the condition, the attach
  /// (the id single-quoted for tmux's parser, `-d` for a move here), the refusal; never a bare
  /// `attach-session` and never `-CC`.
  @Test func buildsTheBoundLocalAttach() throws {
    let identity = BoundSessionIdentity(Self.record)
    #expect(
      PlainLaunch.localAttachArguments(session: identity, detachingOthers: false)
        == [
          "-u", "if-shell", "-F", "-t", "$3", Self.sessionCondition, "attach-session -t '$3'",
          "run-shell 'exit 65'",
        ])
    #expect(
      PlainLaunch.localAttachArguments(session: identity, detachingOthers: true)
        == [
          "-u", "if-shell", "-F", "-t", "$3", Self.sessionCondition,
          "attach-session -d -t '$3'", "run-shell 'exit 65'",
        ])
    #expect(PlainLaunch.sessionChangedStatus == 65)
    let four = try #require(
      PlainLaunch.localAttachArguments(session: Self.fourFields, detachingOthers: false))
    #expect(four.count == 8 && four[5] == Self.fourFields.condition)
  } // End of func buildsTheBoundLocalAttach()

  /// The detach is one `if-shell -F` on the session's id: the session's condition, exactly one
  /// client of that name, and that client with the recorded pid and creation time in the
  /// session of that name; then the detach of that name and the marker.
  @Test func buildsTheBoundDetach() throws {
    let arguments = try #require(
      PlainClientDetach.arguments(of: Self.client, in: BoundSessionIdentity(Self.record)))
    let named = "#{==:#{client_name},/dev/ttys004}"
    let this =
      "#{&&:\(named),#{&&:#{==:#{client_pid},5150},#{&&:#{==:#{client_created},1792600100},"
      + "#{==:#{client_session},muxfinder-test-0a1b2c3d}}}}"
    #expect(
      arguments == [
        "if-shell", "-F", "-t", "$3",
        "#{&&:\(Self.sessionCondition),#{&&:#{==:#{L:#{?\(named),1,}},1},"
          + "#{==:#{L:#{?\(this),1,}},1}}}",
        "detach-client -t '/dev/ttys004'", "display-message -p muxfinder-not-this-client",
      ])
    // Without the session's name the client's session cannot be compared: no detach.
    #expect(PlainClientDetach.arguments(of: Self.client, in: Self.fourFields) == nil)
  } // End of func buildsTheBoundDetach()

  /// Keeping a client (the plain backend's "Detach other clients…", a review fix of I-12c1):
  /// the same command, its condition the detached client's two checks followed by the same two
  /// checks of the kept client, all right-nested; without a kept client exactly the plain
  /// detach; never a detach of the kept client's own name, nor without the session's name.
  @Test func buildsTheBoundDetachKeepingAClient() throws {
    let session = BoundSessionIdentity(Self.record)
    let kept = try #require(
      OtherClient(processID: "6000", created: "1792600050", name: "client-6000"))
    let arguments = try #require(
      PlainClientDetach.arguments(of: Self.client, keeping: kept, in: session))
    /// The two checks of `client` as the condition writes them.
    func checks(_ client: OtherClient) -> (unique: String, this: String) {
      let named = "#{==:#{client_name},\(client.name)}"
      let this =
        "#{&&:\(named),#{&&:#{==:#{client_pid},\(client.processID)},#{&&:#{==:#{client_created},"
        + "\(client.created)},#{==:#{client_session},muxfinder-test-0a1b2c3d}}}}"
      return ("#{==:#{L:#{?\(named),1,}},1}", "#{==:#{L:#{?\(this),1,}},1}")
    }
    let (detached, keeping) = (checks(Self.client), checks(kept))
    #expect(
      arguments == [
        "if-shell", "-F", "-t", "$3",
        "#{&&:\(Self.sessionCondition),#{&&:\(detached.unique),#{&&:\(detached.this),"
          + "#{&&:\(keeping.unique),\(keeping.this)}}}}",
        "detach-client -t '/dev/ttys004'", "display-message -p muxfinder-not-this-client",
      ])
    #expect(
      PlainClientDetach.arguments(of: Self.client, keeping: nil, in: session)
        == PlainClientDetach.arguments(of: Self.client, in: session))
    #expect(PlainClientDetach.arguments(of: Self.client, keeping: Self.client, in: session) == nil)
    let sameName = try #require(
      OtherClient(processID: "6000", created: "1792600050", name: Self.client.name))
    #expect(PlainClientDetach.arguments(of: Self.client, keeping: sameName, in: session) == nil)
    #expect(PlainClientDetach.arguments(of: Self.client, keeping: kept, in: Self.fourFields) == nil)
  } // End of func buildsTheBoundDetachKeepingAClient()

  /// Exit 0 with no output is a detach; exit 0 with the marker line, or tmux's "no server"
  /// error, is another client or none; anything else is a failure.
  @Test func readsTheDetachOutcome() {
    let marker = PlainClientDetach.notThisClientMarker + "\n"
    let cases: [(Int32?, String, String, PlainClientDetach.Outcome)] = [
      (0, "", "", .detached),
      (0, marker, "", .notThisClient),
      (1, "", "no server running on /private/tmp/tmux-501/default\n", .notThisClient),
      (
        1, "", "error connecting to /tmp/tmux-501/default (No such file or directory)\n",
        .notThisClient
      ),
      (0, PlainClientDetach.notThisClientMarker, "", .failed),
      (0, "something\n", "", .failed),
      (0, marker + marker, "", .failed),
      (1, "", "can't find client: /dev/ttys004\n", .failed),
      (1, "", "", .failed),
      (255, "", "Connection to saturno-m4 closed by remote host.\n", .failed),
      (nil, "", "", .failed),
    ]
    for (status, stdout, stderr, expected) in cases {
      #expect(
        PlainClientDetach.outcome(
          exitStatus: status, standardOutput: stdout, standardError: stderr) == expected)
    } // End of loop over the cases
  } // End of func readsTheDetachOutcome()

  // MARK: - On a private server

  /// A control-mode client of the private server, `tmux -u -C attach-session -t <id>`, its
  /// standard input a pipe the test holds open (its name is `client-<pid>`).
  final class ControlClient {
    /// The tmux client.
    let process = Process()
    /// Its standard input.
    let input = Pipe()

    /// Starts the client.
    init(tmux: String, environment: [String: String], sessionID: TmuxSessionID) throws {
      process.executableURL = URL(fileURLWithPath: tmux)
      process.arguments = ["-u", "-C", "attach-session", "-t", sessionID.rawValue]
      process.environment = environment
      process.standardInput = input
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
    }

    /// Waits (at most `seconds`) for the client to exit; its status, or `nil`.
    func exitStatus(within seconds: Int) async -> Int32? {
      for _ in 0..<(seconds * 20) where process.isRunning {
        try? await Task.sleep(for: .milliseconds(50))
      }
      return process.isRunning ? nil : process.terminationStatus
    }

    /// Ends the client (end of file on its input, then SIGTERM) and waits for it.
    func stop() async {
      try? input.fileHandleForWriting.close()
      if await exitStatus(within: 2) == nil { process.terminate() }
      _ = await exitStatus(within: 2)
    }
  } // End of class ControlClient

  /// The private server, its control clients and their reading.
  struct Server {
    /// The tmux executable.
    let tmux: String
    /// The environment that selects the private server.
    let environment: [String: String]

    /// Runs `tmux -u <arguments>`.
    func run(_ arguments: [String]) async throws -> ProcessResult {
      try await DiscoveryEndToEndTests.tmuxResult(
        tmux, ["-u"] + arguments, environment: environment, timeout: .seconds(10))
    }

    /// Creates the detached session `name` running `sleep 60`, starting the private server with
    /// no configuration file (`-f /dev/null`), so no user `tmux.conf` runs.
    func create(_ name: String) async throws -> CreatedSession {
      let result = try await run([
        "-f", "/dev/null", "new-session", "-d", "-P", "-F", CreatedSession.format, "-s", name,
        "sleep", "60",
      ])
      try #require(result.succeeded)
      return try #require(
        CreatedSession.parse(String(decoding: result.standardOutput, as: UTF8.self)))
    }

    /// Waits (at most 3 s) until no server answers, after its last session was killed.
    func waitUntilGone() async throws {
      for _ in 0..<30 {
        guard try await run(["list-sessions"]).succeeded else { return }
        try await Task.sleep(for: .milliseconds(100))
      }
      Issue.record("the private server did not exit")
    } // End of func waitUntilGone()

    /// The attached clients as `<session name>:<pid>:<created>:<name>` lines, sorted.
    func clients() async throws -> [String] {
      let result = try await run([
        "list-clients", "-F", "#{session_name}:#{client_pid}:#{client_created}:#{client_name}",
      ])
      guard result.succeeded else { return [] }
      return String(decoding: result.standardOutput, as: UTF8.self).split(separator: "\n")
        .map(String.init).sorted()
    }

    /// The client whose pid is `pid`, once it is listed (at most 5 s).
    func client(_ pid: Int32) async throws -> OtherClient {
      for _ in 0..<50 {
        for line in try await clients() {
          let fields = line.split(separator: ":").map(String.init)
          if fields.count == 4, fields[1] == String(pid) {
            return try #require(
              OtherClient(processID: fields[1], created: fields[2], name: fields[3]))
          }
        } // End of loop over the listed clients
        try await Task.sleep(for: .milliseconds(100))
      } // End of loop over the looks
      throw CancellationError()
    } // End of func client(_:)

    /// Runs the bound detach of `client` from `session` (keeping `kept`, when given) and reads
    /// its outcome.
    func detach(
      _ client: OtherClient,
      keeping kept: OtherClient? = nil,
      from session: BoundSessionIdentity
    ) async throws -> PlainClientDetach.Outcome {
      let arguments = try #require(
        PlainClientDetach.arguments(of: client, keeping: kept, in: session))
      let result = try await run(arguments)
      return PlainClientDetach.outcome(
        exitStatus: result.exitCode,
        standardOutput: String(decoding: result.standardOutput, as: UTF8.self),
        standardError: String(decoding: result.standardError, as: UTF8.self))
    } // End of func detach(_:keeping:from:)

    /// Runs the bound local attach for `session` with no terminal (standard input
    /// `/dev/null`) and returns its exit status and first error line.
    func attach(_ session: BoundSessionIdentity, detachingOthers: Bool) async throws
      -> (status: Int32?, error: String)
    {
      let arguments = try #require(
        PlainLaunch.localAttachArguments(session: session, detachingOthers: detachingOthers))
      #expect(arguments.first == "-u")
      let result = try await DiscoveryEndToEndTests.tmuxResult(
        tmux, arguments, environment: environment, timeout: .seconds(10))
      let error = String(decoding: result.standardError, as: UTF8.self)
      return (result.exitCode, error.split(separator: "\n").first.map(String.init) ?? "")
    } // End of func attach(_:detachingOthers:)
  } // End of struct Server

  /// Runs `body` with a private server under a short private `TMUX_TMPDIR`, then kills its
  /// `muxfinder-test-*` sessions.
  static func withPrivateServer(_ body: (Server) async throws -> Void) async throws {
    let tmux = try #require(DiscoveryEndToEndTests.tmuxPath)
    let directory = try TestSupport.makeShortTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var root = directory.path(percentEncoded: false)
    if root.hasSuffix("/") { root.removeLast() }
    let server = Server(
      tmux: tmux,
      environment: [
        "PATH": ProcessEnvironment.systemSearchPath, "HOME": root, "TMUX_TMPDIR": root,
      ])
    do {
      try await body(server)
    } catch {
      await DiscoveryEndToEndTests.cleanUp([], tmux: tmux, environment: server.environment)
      throw error
    }
    await DiscoveryEndToEndTests.cleanUp([], tmux: tmux, environment: server.environment)
  } // End of static func withPrivateServer(_:)

  /// The recorded session with each field off in turn: another session's id, a missing id,
  /// the creation time, the server pid and start time (a restarted server), the socket, the
  /// name, another session's name.
  static func variants(of target: CreatedSession, other: CreatedSession)
    -> [BoundSessionIdentity]
  {
    var variants = Array(repeating: BoundSessionIdentity(target), count: 8)
    variants[0].sessionID = other.sessionID
    variants[1].sessionID = TmuxSessionID("$999")!
    variants[2].createdAt += 1
    variants[3].serverPID += 1
    variants[4].serverStartTime -= 1
    variants[5].socketPath! += "x"
    variants[6].name! += "x"
    variants[7].name = other.name
    return variants
  } // End of static func variants(of:other:)

  /// On a private server: a restarted server whose new session has the old id and name is
  /// refused for the old record (exit 65, the review's case); the bound attach for the exact
  /// session gets as far as tmux's attach (with no terminal, `open terminal failed`), and for
  /// every variant attaches nothing and exits 65, a move here detaching nobody; with no server
  /// it exits 1 and starts none. Only `muxfinder-test-*` sessions.
  @Test(.enabled(if: DiscoveryEndToEndTests.tmuxPath != nil), .timeLimit(.minutes(1)))
  func bindsTheAttachOnAPrivateServer() async throws {
    try await Self.withPrivateServer { server in
      let first = try await server.create("muxfinder-test-restart")
      _ = try await server.run(["kill-session", "-t", first.sessionID.rawValue])
      try await server.waitUntilGone()
      let restarted = try await server.create("muxfinder-test-restart")
      #expect(restarted.sessionID == first.sessionID && restarted.name == first.name)
      #expect(restarted.server.pid != first.server.pid)
      for detachingOthers in [false, true] {
        let old = try await server.attach(
          BoundSessionIdentity(first), detachingOthers: detachingOthers)
        #expect(old.status == PlainLaunch.sessionChangedStatus)
      }
      let other = try await server.create("muxfinder-test-other")
      let target = try await server.create("muxfinder-test-a ##ü, x} 日本 ;x")
      let watcher = try ControlClient(
        tmux: server.tmux, environment: server.environment, sessionID: target.sessionID)
      do {
        _ = try await server.client(watcher.process.processIdentifier)
        let attached = try await server.clients()
        for detachingOthers in [false, true] {
          let exact = try await server.attach(
            BoundSessionIdentity(target), detachingOthers: detachingOthers)
          #expect(exact.status == 1 && exact.error == "open terminal failed: not a terminal")
          for variant in Self.variants(of: target, other: other) {
            let refused = try await server.attach(variant, detachingOthers: detachingOthers)
            #expect(refused.status == PlainLaunch.sessionChangedStatus, "\(variant)")
            #expect(try await server.clients() == attached)
          } // End of loop over the variants
        } // End of loop over attach and move here
        #expect(watcher.process.isRunning)
      } catch {
        await watcher.stop()
        throw error
      }
      await watcher.stop()
      for session in [restarted, target, other] {
        _ = try await server.run(["kill-session", "-t", session.sessionID.rawValue])
      }
      try await server.waitUntilGone()
      let none = try await server.attach(BoundSessionIdentity(target), detachingOthers: false)
      #expect(none.status == 1)
      #expect(!(try await server.run(["list-sessions"]).succeeded))
    }
  } // End of func bindsTheAttachOnAPrivateServer()

  /// On a private server with control clients C1 and C2 on one session and C3 on another: the
  /// bound detach of C1 with any session field, its pid, its creation time or its name off,
  /// or of C3 against C1's session, detaches nothing; the exact one detaches C1 alone (it
  /// exits 0); again, it finds nothing. Only `muxfinder-test-*` sessions.
  @Test(.enabled(if: DiscoveryEndToEndTests.tmuxPath != nil), .timeLimit(.minutes(1)))
  func bindsTheDetachOnAPrivateServer() async throws {
    try await Self.withPrivateServer { server in
      let target = try await server.create("muxfinder-test-d #, x}")
      let other = try await server.create("muxfinder-test-other")
      var started: [ControlClient] = []
      do {
        for id in [target.sessionID, target.sessionID, other.sessionID] {
          started.append(
            try ControlClient(tmux: server.tmux, environment: server.environment, sessionID: id))
        }
        try await Self.checkDetaches(on: server, target: target, other: other, started: started)
      } catch {
        for client in started { await client.stop() }
        throw error
      }
      for client in started { await client.stop() }
    }
  } // End of func bindsTheDetachOnAPrivateServer()

  /// The checks of `bindsTheDetachOnAPrivateServer()`, with `started` its three control
  /// clients (two on `target`, one on `other`).
  static func checkDetaches(
    on server: Server,
    target: CreatedSession,
    other: CreatedSession,
    started: [ControlClient]
  ) async throws {
    var listed: [OtherClient] = []
    for client in started {
      listed.append(try await server.client(client.process.processIdentifier))
    }
    let all = try await server.clients()
    #expect(all.count == 3)
    let session = BoundSessionIdentity(target)
    let first = listed[0]
    let offClients = [
      try #require(
        OtherClient(
          processID: String(first.processID + 1), created: String(first.created),
          name: first.name)),
      try #require(
        OtherClient(
          processID: String(first.processID), created: String(first.created + 1),
          name: first.name)),
      try #require(
        OtherClient(
          processID: String(first.processID), created: String(first.created),
          name: listed[1].name)),
      listed[2],
    ]
    for client in offClients {
      #expect(try await server.detach(client, from: session) == .notThisClient, "\(client)")
      #expect(try await server.clients() == all)
    } // End of loop over the clients off by one field
    for variant in variants(of: target, other: other) {
      #expect(try await server.detach(first, from: variant) == .notThisClient, "\(variant)")
      #expect(try await server.clients() == all)
    } // End of loop over the session variants
    #expect(try await server.detach(first, from: session) == .detached)
    #expect(await started[0].exitStatus(within: 5) == 0)
    #expect(try await server.clients() == all.filter { !$0.hasSuffix(":" + first.name) })
    #expect(try await server.detach(first, from: session) == .notThisClient)
    #expect(started[1].process.isRunning && started[2].process.isRunning)
  } // End of static func checkDetaches(on:target:other:started:)

  /// On a private server with control clients K (kept), O1 and O2 on one session (a review fix
  /// of I-12c1): the bound detach of O1 keeping K with K's pid, creation time or name off
  /// detaches nothing; keeping K exactly, it detaches O1 alone; once K switched to another
  /// session, and again once K ended, the detach of O2 keeping K detaches nothing, while O2's
  /// detach with no kept client still does (so those refusals were K's). Only
  /// `muxfinder-test-*` sessions.
  @Test(.enabled(if: DiscoveryEndToEndTests.tmuxPath != nil), .timeLimit(.minutes(1)))
  func bindsTheDetachToTheKeptClientOnAPrivateServer() async throws {
    try await Self.withPrivateServer { server in
      let target = try await server.create("muxfinder-test-k #, x}")
      let other = try await server.create("muxfinder-test-other")
      var started: [ControlClient] = []
      do {
        for _ in 0..<3 {
          started.append(
            try ControlClient(
              tmux: server.tmux, environment: server.environment, sessionID: target.sessionID))
        }
        try await Self.checkKeptDetaches(
          on: server, target: target, other: other, started: started)
      } catch {
        for client in started { await client.stop() }
        throw error
      }
      for client in started { await client.stop() }
    }
  } // End of func bindsTheDetachToTheKeptClientOnAPrivateServer()

  /// The checks of `bindsTheDetachToTheKeptClientOnAPrivateServer()`, with `started` its three
  /// control clients on `target` (K, O1, O2).
  static func checkKeptDetaches(
    on server: Server,
    target: CreatedSession,
    other: CreatedSession,
    started: [ControlClient]
  ) async throws {
    var listed: [OtherClient] = []
    for client in started {
      listed.append(try await server.client(client.process.processIdentifier))
    }
    let (kept, first, second) = (listed[0], listed[1], listed[2])
    let session = BoundSessionIdentity(target)
    let all = try await server.clients()
    #expect(all.count == 3)
    let offKept = [
      try #require(
        OtherClient(
          processID: String(kept.processID + 1), created: String(kept.created), name: kept.name)),
      try #require(
        OtherClient(
          processID: String(kept.processID), created: String(kept.created + 1), name: kept.name)),
      try #require(
        OtherClient(
          processID: String(kept.processID), created: String(kept.created), name: second.name)),
    ]
    for off in offKept {
      #expect(try await server.detach(first, keeping: off, from: session) == .notThisClient)
      #expect(try await server.clients() == all, "\(off)")
    } // End of loop over the kept clients off by one field
    #expect(try await server.detach(first, keeping: kept, from: session) == .detached)
    #expect(await started[1].exitStatus(within: 5) == 0)
    // K moves to another session: O2 is not detached keeping it.
    let switched = try await server.run([
      "switch-client", "-c", kept.name, "-t", other.sessionID.rawValue,
    ])
    #expect(switched.succeeded)
    let afterSwitch = try await server.clients()
    #expect(afterSwitch.contains("\(other.name):\(kept.processID):\(kept.created):\(kept.name)"))
    #expect(try await server.detach(second, keeping: kept, from: session) == .notThisClient)
    #expect(try await server.clients() == afterSwitch)
    // K ends: O2 is still not detached keeping it.
    await started[0].stop()
    for _ in 0..<50 {
      if try await server.clients().count == 1 { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(try await server.clients().count == 1)
    #expect(try await server.detach(second, keeping: kept, from: session) == .notThisClient)
    #expect(started[2].process.isRunning)
    // With no kept client the same detach goes through.
    #expect(try await server.detach(second, from: session) == .detached)
    #expect(await started[2].exitStatus(within: 5) == 0)
  } // End of static func checkKeptDetaches(on:target:other:started:)
} // End of struct PlainBoundCommandsTests
