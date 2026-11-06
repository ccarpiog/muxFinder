import Darwin
import Foundation
import Testing
import os

@testable import MuxFinderCore

/// `ProcessFolderSearchTransport` and `StreamingProcess` (PLAN.md D3, D36): the argv for This
/// Mac and for ssh, and real local processes running the static script over stub `mdfind` and
/// `mdutil` (no Spotlight, no ssh): events, the end at end of input, termination of a script
/// that does not end, a disconnect seen from the host's side, the bounded event buffer, and no
/// process left behind.
@Suite("Folder search transport")
struct FolderSearchTransportTests {
  /// Reads `connection`'s events into a list the test can wait on.
  final class EventLog: Sendable {
    /// The events so far.
    private let events = OSAllocatedUnfairLock<[FolderSearchConnectionEvent]>(initialState: [])
    /// The reading task.
    private let reader: Task<Void, Never>

    /// Starts reading `connection`.
    init(_ connection: any FolderSearchConnection) {
      let events = self.events
      reader = Task {
        for await event in connection.events { events.withLock { $0.append(event) } }
      }
    }

    /// The events so far.
    var all: [FolderSearchConnectionEvent] { events.withLock { $0 } }

    /// Waits until an event matches `predicate`; returns it.
    func wait(
      within limit: Duration = .seconds(10),
      for predicate: @escaping (FolderSearchConnectionEvent) -> Bool
    ) async -> FolderSearchConnectionEvent? {
      _ = await FolderSearchWait.until(within: limit) { self.all.contains(where: predicate) }
      return all.first(where: predicate)
    }

    /// Waits until the reading ends.
    func finished() async { await reader.value }
  }

  /// The script on the host's side of an SSH connection: spawned in a process group of its own
  /// with pipes whose far ends the test holds, as `sshd` holds a remote command's. Closing them
  /// is all a disconnect does there (no signal reaches the script).
  final class HostSideScript {
    /// The script's pid, also its process group id.
    let processID: pid_t
    /// The write end of its standard input, or -1 once closed.
    private var input: Int32
    /// The read end of its standard output, or -1 once closed.
    private var output: Int32
    /// The read end of its standard error, or -1 once closed.
    private var errors: Int32
    /// Whether it was reaped.
    private var reaped = false

    /// Starts the static script through `shell` with `environment`.
    init(shell: String, environment: [String: String]) throws {
      let request = ProcessRequest(
        executableURL: URL(fileURLWithPath: shell),
        arguments: ["-c", FolderSearchScript.script.source, ShellQuoting.scriptName],
        environment: environment, standardInput: .data(Data()))
      let parameters = try ProcessSupervisor.launchParameters(for: request)
      let supervisor = ProcessSupervisor(
        request: request, terminationGracePeriod: .zero, outputDrainGracePeriod: .zero,
        control: ProcessRunControl())
      let child = try supervisor.spawn(
        path: parameters.path, argv: try CStringArray(parameters.argv),
        envp: try CStringArray(parameters.environment))
      processID = child.processID
      input = child.standardInput
      output = child.standardOutput
      errors = child.standardError
    } // End of init(shell:environment:)

    /// Reads standard output until the header's last record, `ready`, within `limit`.
    func readHeader(within limit: Duration = .seconds(10)) async -> Bool {
      var received: [UInt8] = []
      var buffer = [UInt8](repeating: 0, count: 4096)
      let ready = Array("ready".utf8) + [0]
      return await FolderSearchWait.until(within: limit) {
        let count = buffer.withUnsafeMutableBytes { read(self.output, $0.baseAddress, $0.count) }
        if count > 0 { received += buffer[..<count] }
        return received.count >= ready.count && Array(received.suffix(ready.count)) == ready
      }
    } // End of func readHeader(within:)

    /// Writes `line` to standard input.
    func write(_ line: Data) -> Bool {
      line.withUnsafeBytes { Darwin.write(input, $0.baseAddress, $0.count) } == line.count
    }

    /// Closes the test's ends of all three pipes, as a dropped connection does.
    func disconnect() {
      for descriptor in [input, output, errors] where descriptor >= 0 { close(descriptor) }
      input = -1
      output = -1
      errors = -1
    }

    /// Reaps the script if it has exited; returns whether it was reaped.
    func reapIfExited() -> Bool {
      guard !reaped else { return true }
      var status: Int32 = 0
      reaped = waitpid(processID, &status, WNOHANG) == processID
      return reaped
    }

    /// Kills whatever is left of the script's group and reaps it (cleanup after a failure).
    func end() {
      disconnect()
      guard !reaped else { return }
      _ = kill(-processID, SIGKILL)
      var status: Int32 = 0
      _ = waitpid(processID, &status, 0)
      reaped = true
    }
  } // End of class HostSideScript

  /// Whether `event` is the header.
  static func isHeader(_ event: FolderSearchConnectionEvent) -> Bool {
    if case .header = event { return true }
    return false
  }

  /// Whether `event` is a reply.
  static func isReply(_ event: FolderSearchConnectionEvent) -> Bool {
    if case .reply = event { return true }
    return false
  }

  /// Whether `event` is the end.
  static func isEnd(_ event: FolderSearchConnectionEvent) -> Bool {
    if case .ended = event { return true }
    return false
  }

  /// This Mac runs `/bin/sh -c <script> muxfinder` with the system search path; ssh gets
  /// discovery's options, `-T` and no `-n`, then `--`, the destination and the D3 string.
  @Test func buildsTheArgv() throws {
    let transport = ProcessFolderSearchTransport(
      localEnvironment: ProcessFolderSearchTransport.defaultLocalEnvironment(
        base: ["PATH": "/opt/homebrew/bin:/usr/bin", "TMUX": "x", "TMUX_PANE": "%1", "HOME": "/h"]),
      sshEnvironment: ["PATH": ProcessEnvironment.systemSearchPath])
    let local = try transport.request(for: .local)
    #expect(local.executableURL.path == "/bin/sh")
    #expect(local.arguments == ["-c", FolderSearchScript.script.source, "muxfinder"])
    #expect(local.environment == ["PATH": ProcessEnvironment.systemSearchPath, "HOME": "/h"])
    let ssh = try transport.request(for: .ssh(destination: "saturno-m4"))
    #expect(ssh.executableURL.path == "/usr/bin/ssh")
    #expect(
      ssh.arguments
        == DiscoveryProbe.sshOptions + [
          "-T", "--", "saturno-m4",
          ShellQuoting.remoteCommand(script: FolderSearchScript.script, args: []),
        ])
    #expect(!ssh.arguments.contains("-n"))
    #expect(throws: FolderSearchFailure.self) {
      try transport.request(for: .ssh(destination: "-oProxyCommand=x"))
    }
    #expect(throws: FolderSearchFailure.self) {
      try transport.request(for: .ssh(destination: "a b"))
    }
    #expect(
      FolderSearchHost(HostConfig(displayName: "S", mode: .ssh, sshDestination: "s1"))
        == .ssh(destination: "s1"))
    #expect(FolderSearchHost(HostConfig(displayName: "M", mode: .local)) == .local)
  } // End of func buildsTheArgv()

  /// A local script writes its header, answers a line, and ends when its standard input is
  /// closed; nothing of its group is left.
  @Test func answersAndEndsAtEndOfInput() async throws {
    let sandbox = try FolderSearchSandbox()
    defer { sandbox.remove() }
    try sandbox.writePaths(["/syn/one", "/syn/.two", "/syn/three"])
    let transport = ProcessFolderSearchTransport(localEnvironment: sandbox.environment())
    let connection = try await transport.open(.local)
    let processID = try #require(connection as? ProcessFolderSearchConnection).processID
    let log = EventLog(connection)
    #expect(await log.wait(for: Self.isHeader) != nil)
    let name = try FolderSearchText.nameText(for: "ab")
    #expect(connection.send(FolderSearchScript.queryLine(id: 1, scope: .disk, name: name)))
    let reply = await log.wait(for: Self.isReply)
    #expect(
      reply == .reply(FolderSearchReply(id: 1, status: .ok, paths: ["/syn/one", "/syn/three"])))
    let started = ContinuousClock.now
    await connection.close()
    #expect(ContinuousClock.now - started < .seconds(2))
    await log.finished()
    #expect(log.all.last == .ended(FolderSearchConnectionEnd(termination: .exited(0))))
    #expect(TestSupport.processGroupIsGone(processID))
    #expect(!connection.send(FolderSearchScript.queryLine(id: 2, scope: .disk, name: name)))
  } // End of func answersAndEndsAtEndOfInput()

  /// A script stuck in a search is terminated after the grace period: `close()` returns once
  /// it is reaped, and no member of its group (the stub's `sleep` included) is left.
  @Test func terminatesAStuckScript() async throws {
    let sandbox = try FolderSearchSandbox()
    defer { sandbox.remove() }
    let transport = ProcessFolderSearchTransport(
      localEnvironment: sandbox.environment(mode: "hang"))
    let connection = try await transport.open(.local)
    let processID = try #require(connection as? ProcessFolderSearchConnection).processID
    let log = EventLog(connection)
    #expect(await log.wait(for: Self.isHeader) != nil)
    #expect(
      connection.send(
        FolderSearchScript.queryLine(
          id: 1, scope: .home, name: try FolderSearchText.nameText(for: "ab"))))
    #expect(await FolderSearchWait.until { !sandbox.mdfindCalls().isEmpty })
    let started = ContinuousClock.now
    await connection.close()
    let elapsed = ContinuousClock.now - started
    #expect(elapsed >= ProcessFolderSearchTransport.closeGracePeriod)
    #expect(elapsed < .seconds(8))
    await log.finished()
    #expect(log.all.contains(where: Self.isEnd))
    #expect(TestSupport.processGroupIsGone(processID))
  } // End of func terminatesAStuckScript()

  /// A script that ends by itself is reported once, with its status and standard error.
  @Test func reportsAnEndByItself() async throws {
    let request = ProcessRequest(
      executableURL: TestSupport.shell, arguments: ["-c", "printf 'why' >&2; exit 3"],
      environment: TestSupport.environment)
    let connection = try ProcessFolderSearchConnection.start(request)
    let log = EventLog(connection)
    await log.finished()
    #expect(
      log.all == [
        .ended(FolderSearchConnectionEnd(termination: .exited(3), standardError: Data("why".utf8)))
      ])
    await connection.close()
  } // End of func reportsAnEndByItself()

  /// Output that is not the script's stops the reading after one protocol error; closing then
  /// ends the process, which is left running otherwise.
  @Test func stopsReadingAtAProtocolError() async throws {
    let header = FolderSearchOutputTests.header().map { String(format: "\\%03o", $0) }.joined()
    let request = ProcessRequest(
      executableURL: TestSupport.shell,
      arguments: ["-c", "printf '\(header)'; printf 'garbage\\000/x\\000'; exec sleep 30"],
      environment: TestSupport.environment)
    let connection = try ProcessFolderSearchConnection.start(request)
    let processID = connection.processID
    let log = EventLog(connection)
    #expect(await log.wait(for: { $0 == .protocolError(.unexpectedRecord) }) != nil)
    await connection.close()
    await log.finished()
    #expect(
      log.all.filter { if case .protocolError = $0 { return true } else { return false } }.count
        == 1)
    #expect(!log.all.contains(where: Self.isReply))
    #expect(TestSupport.processGroupIsGone(processID))
  } // End of func stopsReadingAtAProtocolError()

  /// The blocker of a closed SSH channel: closing ssh ends only the local process, so on the
  /// host the script only sees its standard input end and its standard output go. A search
  /// blocked there is still stopped by the host's deadline: the stub `mdfind` is gone, the
  /// script exits by itself and nothing of its group is left, all without a signal from here.
  @Test(arguments: FolderSearchSandbox.shells)
  func aDisconnectEndsABlockedSearchOnTheHost(shell: String) async throws {
    let sandbox = try FolderSearchSandbox()
    defer { sandbox.remove() }
    let script = try HostSideScript(shell: shell, environment: sandbox.environment(mode: "hang"))
    defer { script.end() }
    #expect(await script.readHeader())
    let name = try FolderSearchText.nameText(for: "ab")
    #expect(script.write(FolderSearchScript.queryLine(id: 1, scope: .disk, name: name)))
    #expect(await FolderSearchWait.until { !sandbox.mdfindProcessIDs().isEmpty })
    script.disconnect()
    let limit = FolderSearchScript.searchDeadline + .seconds(4)
    #expect(await sandbox.noStubLeft(within: limit))
    #expect(await TestSupport.eventually(within: limit) { script.reapIfExited() })
    #expect(TestSupport.processGroupIsGone(script.processID))
  } // End of func aDisconnectEndsABlockedSearchOnTheHost(shell:)

  /// A flood of valid answers that nobody reads overflows the bounded event buffer: the
  /// connection reports `eventOverflow` and ends the process by itself (no `close()`), and the
  /// reader later gets the buffered events, the overflow and the end, last.
  @Test func failsOnAFloodWithAStalledReader() async throws {
    let header = FolderSearchOutputTests.header().map { String(format: "\\%03o", $0) }.joined()
    let request = ProcessRequest(
      executableURL: TestSupport.shell,
      arguments: ["-c", "printf '\(header)'; while :; do printf 'end 1 ok 0\\000'; done"],
      environment: TestSupport.environment)
    let connection = try ProcessFolderSearchConnection.start(request, eventLimit: 4)
    let processID = connection.processID
    let gone = await TestSupport.eventually(within: .seconds(8)) {
      TestSupport.processGroupIsGone(processID)
    }
    #expect(gone)
    var events: [FolderSearchConnectionEvent] = []
    for await event in connection.events {
      events.append(event)
      if events.count == 20 { break }
    } // End of loop over the buffered events
    await connection.close()
    let reply = FolderSearchConnectionEvent.reply(FolderSearchReply(id: 1, status: .ok, paths: []))
    #expect(events.count == 7)
    #expect(events.first == .header(FolderSearchOutputTests.expectedHeader))
    #expect(Array(events.dropFirst().prefix(4)) == Array(repeating: reply, count: 4))
    #expect(events.dropFirst(5).first == .protocolError(.eventOverflow))
    #expect(events.last.map(Self.isEnd) == true)
    #expect(TestSupport.processGroupIsGone(processID))
  } // End of func failsOnAFloodWithAStalledReader()

  /// The D3 string ssh would send, parsed by `zsh` and `bash` as a remote login shell parses it,
  /// still runs the static script byte for byte.
  @Test(arguments: [["/bin/zsh", "-f"], ["/bin/bash", "--norc", "--noprofile"]])
  func remoteCommandSurvivesALoginShell(shell: [String]) async throws {
    let sandbox = try FolderSearchSandbox()
    defer { sandbox.remove() }
    try sandbox.writePaths(["/syn/remote"])
    let command = ShellQuoting.remoteCommand(script: FolderSearchScript.script, args: [])
    let request = ProcessRequest(
      executableURL: URL(fileURLWithPath: shell[0]),
      arguments: Array(shell.dropFirst()) + ["-c", command],
      environment: sandbox.environment())
    let connection = try ProcessFolderSearchConnection.start(request)
    let log = EventLog(connection)
    #expect(await log.wait(for: Self.isHeader) != nil)
    #expect(
      connection.send(
        FolderSearchScript.queryLine(
          id: 5, scope: .disk, name: try FolderSearchText.nameText(for: "re"))))
    #expect(
      await log.wait(for: Self.isReply)
        == .reply(FolderSearchReply(id: 5, status: .ok, paths: ["/syn/remote"])))
    await connection.close()
    await log.finished()
  } // End of func remoteCommandSurvivesALoginShell(shell:)
}
