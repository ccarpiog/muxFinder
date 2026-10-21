import Foundation
import Testing

@testable import MuxFinderCore

/// End-to-end discovery against a real tmux, kept hermetic: the server lives in a private
/// `TMUX_TMPDIR` under `/tmp`, starts with `-f /dev/null` (no user config), only ever holds
/// `muxfinder-test-*` sessions running `sleep 60`, and is never the user's server. Skipped when
/// no tmux is installed.
@Suite("Discovery end to end (private tmux server)")
struct DiscoveryEndToEndTests {
  /// A session the test created: its `$N` id and its name.
  typealias TestSession = (id: String, name: String)

  /// The first installed tmux among the locator's candidates, if any.
  static let tmuxPath: String? = TmuxLocator.candidatePaths.first {
    FileManager.default.isExecutableFile(atPath: $0)
  }

  /// The prefix every session this suite creates or kills must have (CLAUDE.md safety rules).
  static let sessionPrefix = "muxfinder-test-"

  /// The longest a cleanup may take; it stops issuing tmux commands after this.
  static let cleanupTimeLimit: Duration = .seconds(20)

  /// The longest a single cleanup tmux command may take.
  static let cleanupCommandTimeout: Duration = .seconds(5)

  /// Session names created by the test: Unicode, emoji and shell metacharacters. `%@` is
  /// replaced by the private directory, so a `$(touch …)` that ever ran would leave a file
  /// there.
  static let nameTemplates = [
    "muxfinder-test-plain",
    "muxfinder-test-ünïcödé-日本-🧪",
    "muxfinder-test-$(touch %@/injected)",
    "muxfinder-test-a;rm -rf ~ `id` \"dq\" 'sq'",
    "muxfinder-test-👨‍👩‍👧 emoji",
  ]

  /// Creates sessions, discovers them with the real probe, checks ids and names, and cleans up.
  @Test(.enabled(if: tmuxPath != nil), .timeLimit(.minutes(1)))
  func discoversSessionsOnAPrivateServer() async throws {
    let tmux = try #require(Self.tmuxPath)
    let directory = try TestSupport.makeShortTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let directoryPath = directory.path(percentEncoded: false)
    let tmuxEnvironment = Self.tmuxEnvironment(directory)
    // TMUX and TMUX_PANE point elsewhere, as inside a tmux pane; discovery must ignore them.
    var probeEnvironment = tmuxEnvironment
    probeEnvironment["TMUX"] = "/private/tmp/muxfinder-test-nonexistent/default,1,0"
    probeEnvironment["TMUX_PANE"] = "%1"
    let probe = DiscoveryProbe(runner: TestSupport.fastRunner, baseEnvironment: probeEnvironment)
    let host = HostConfig(displayName: "This Mac", mode: .local)

    #expect(try await probe.discover(host).status == .noServer)

    let names = Self.nameTemplates.map { $0.replacingOccurrences(of: "%@", with: directoryPath) }
    try await Self.withTestSessions(names, tmux: tmux, environment: tmuxEnvironment) { created in
      let result = try await probe.discover(host)
      let found = Dictionary(
        uniqueKeysWithValues: result.status.sessions.map { ($0.key.sessionID.rawValue, $0) }
      )
      #expect(found.count == created.count, "\(result.status)")
      for (id, name) in created {
        #expect(found[id]?.name == name)
        #expect(found[id]?.key.hostID == host.id)
        #expect(found[id]?.key.server.socketPath.hasSuffix("/tmux-\(getuid())/default") == true)
      }
      #expect(Set(found.values.map(\.key.server)).count == 1)
      #expect(!TestSupport.fileExists("injected", in: directory))
    }
    #expect(try await probe.discover(host).status == .noServer)
  } // End of func discoversSessionsOnAPrivateServer()

  /// A task cancelled while its sessions exist still kills them: cleanup runs in a task of its
  /// own, where the runner does not refuse to start tmux.
  @Test(.enabled(if: tmuxPath != nil), .timeLimit(.minutes(1)))
  func cleansUpWhenTheTaskIsCancelled() async throws {
    let tmux = try #require(Self.tmuxPath)
    let directory = try TestSupport.makeShortTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let environment = Self.tmuxEnvironment(directory)
    let name = Self.sessionPrefix + "cancelled"

    let run = Task {
      try await Self.withTestSessions([name], tmux: tmux, environment: environment) { created in
        let listed = try await Self.listSessions(tmux: tmux, environment: environment)
        #expect(listed?.map(\.id) == created.map(\.id))
        withUnsafeCurrentTask { $0?.cancel() }
        try Task.checkCancellation()
      }
    }
    await #expect(throws: CancellationError.self) { try await run.value }
    let remaining = try await Self.listSessions(tmux: tmux, environment: environment) ?? []
    #expect(remaining.isEmpty, "left behind: \(remaining.map(\.id))")
  } // End of func cleansUpWhenTheTaskIsCancelled()

  /// The environment that points tmux at the private server under `directory`.
  static func tmuxEnvironment(_ directory: URL) -> [String: String] {
    [
      "PATH": ProcessEnvironment.systemSearchPath,
      "HOME": NSHomeDirectory(),
      "TMUX_TMPDIR": directory.path(percentEncoded: false),
    ]
  }

  /// Creates one session per name on the private server (each running `sleep 60`), runs `body`
  /// with their ids and names, and always cleans up with `cleanUp(_:tmux:environment:)`, also
  /// when creating a session or `body` throws, and when the task is cancelled.
  static func withTestSessions(
    _ names: [String],
    tmux: String,
    environment: [String: String],
    _ body: ([TestSession]) async throws -> Void
  ) async throws {
    var created: [TestSession] = []
    do {
      for name in names {
        try #require(name.hasPrefix(sessionPrefix))
        let id = try await runTmux(
          tmux,
          [
            "-f", "/dev/null", "new-session", "-d", "-P", "-F", "#{session_id}", "-s", name,
            "sleep", "60",
          ],
          environment: environment
        )
        created.append((id.trimmingCharacters(in: .whitespacesAndNewlines), name))
      } // End of loop over session names
      try await body(created)
    } catch {
      await cleanUp(created.map(\.id), tmux: tmux, environment: environment)
      throw error
    }
    await cleanUp(created.map(\.id), tmux: tmux, environment: environment)
  } // End of func withTestSessions(_:tmux:environment:_:)

  /// Kills the test's sessions on the private server and waits until that is done.
  ///
  /// The work runs in a new unstructured task, which does not inherit the caller's
  /// cancellation: in a cancelled task every runner call throws before starting tmux, so
  /// cleanup there would leak the sessions. It kills every `muxfinder-test-*` session the
  /// server lists (which also catches one created just before a cancellation, before its id was
  /// recorded) or, if listing fails, the recorded `ids`. It never kills other sessions or the
  /// server itself; the server exits once its last session is gone. Each tmux command has a
  /// short timeout, and no new one starts after `cleanupTimeLimit`.
  static func cleanUp(_ ids: [String], tmux: String, environment: [String: String]) async {
    await Task {
      let clock = ContinuousClock()
      let deadline = clock.now + cleanupTimeLimit
      var targets = ids
      if let listed = try? await listSessions(tmux: tmux, environment: environment) {
        targets = listed.filter { $0.name.hasPrefix(sessionPrefix) }.map(\.id)
      }
      for id in targets {
        let remaining = deadline - clock.now
        guard remaining > .zero else { break }
        _ = try? await tmuxResult(
          tmux,
          ["kill-session", "-t", id],
          environment: environment,
          timeout: min(cleanupCommandTimeout, remaining)
        )
      } // End of loop over cleanup targets
    }.value
  } // End of func cleanUp(_:tmux:environment:)

  /// The private server's sessions, or `nil` when tmux cannot list them (on the private server
  /// that means no server is running). Uses `-u` so tabs and Unicode survive (PLAN.md D12).
  static func listSessions(
    tmux: String,
    environment: [String: String]
  ) async throws -> [TestSession]? {
    let result = try await tmuxResult(
      tmux,
      ["-u", "list-sessions", "-F", "#{session_id}\t#{session_name}"],
      environment: environment,
      timeout: cleanupCommandTimeout
    )
    guard result.succeeded else { return nil }
    let lines = String(decoding: result.standardOutput, as: UTF8.self).split(separator: "\n")
    return lines.compactMap { line in
      let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
      return fields.count == 2 ? (String(fields[0]), String(fields[1])) : nil
    }
  } // End of func listSessions(tmux:environment:)

  /// Runs tmux with `arguments` and returns its stdout; fails the test on a non-zero exit.
  static func runTmux(
    _ tmux: String,
    _ arguments: [String],
    environment: [String: String]
  ) async throws -> String {
    let result = try await tmuxResult(
      tmux,
      arguments,
      environment: environment,
      timeout: .seconds(10)
    )
    try #require(
      result.succeeded,
      "tmux failed: \(String(decoding: result.standardError, as: UTF8.self))"
    )
    return String(decoding: result.standardOutput, as: UTF8.self)
  } // End of func runTmux(_:_:environment:)

  /// Runs tmux with `arguments` and returns the raw result, without judging it.
  static func tmuxResult(
    _ tmux: String,
    _ arguments: [String],
    environment: [String: String],
    timeout: Duration
  ) async throws -> ProcessResult {
    try await TestSupport.fastRunner.run(
      ProcessRequest(
        executableURL: URL(fileURLWithPath: tmux),
        arguments: arguments,
        environment: environment,
        timeout: timeout
      )
    )
  } // End of func tmuxResult(_:_:environment:timeout:)
}
