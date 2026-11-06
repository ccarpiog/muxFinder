import AppKit
import Foundation
import Testing

@testable import MuxFinderCore

/// The plain backend's open on this Mac (PLAN.md D38, Phase I-12c2) over test fakes: a session
/// whose client on This Mac descends from a terminal app becomes a focus of that app, nothing
/// opened (D16's "never a duplicate"); the backend's own record comes first; unmapped clients
/// and an unreadable table never block; the activation's outcome never fails the attach and a
/// non-running app is never launched; a move here and an SSH host are unchanged; an `.app`
/// handle is activated by either backend. No terminal app, iTerm2, tmux or ssh is ever run;
/// the process table is a fake.
@Suite("Plain terminal backend: open on this Mac")
@MainActor
struct PlainTerminalBackendOpenHereTests {
  /// Shorthand.
  typealias Support = PlainBackendSupport
  /// Shorthand.
  typealias Local = LocalClientSupport

  /// The fixture session `$3` on `host` with `clients`.
  static func session(
    on host: HostConfig = AttachTestSupport.host,
    clients: [ClientSummary]
  ) -> DiscoveredSession {
    var session = Support.session(on: host)
    session.clients = clients
    return session
  }

  /// A harness for `loaded` (Terminal by default) whose discovery lists `session`, with an
  /// attributor over `table` and `activator`.
  static func harness(
    _ session: DiscoveredSession,
    table: FakeProcessTable,
    activator: FakeTerminalAppActivator,
    loaded: LoadedTerminalDefinition? = nil,
    answer: ScriptedProcessRunner.Answer? = nil
  ) throws -> PlainBackendHarness {
    let defaultAnswer: ScriptedProcessRunner.Answer = { _, _ in
      Support.listing(Support.listingLine())
    }
    return try PlainBackendHarness(
      loaded: loaded, sessions: [session], answer: answer ?? defaultAnswer,
      localClients: Local.attributor(table), appActivator: activator)
  } // End of static func harness(_:table:activator:loaded:answer:)

  /// Terminal's client: the attach brings Terminal forward and ends `appFocused`, a focus, with
  /// the client and the activation in the result; no request, no window, no tmux command; the
  /// table read once for the one client.
  @Test func focusesTheAppInsteadOfOpening() async throws {
    let table = Local.table(Local.terminalChain())
    let activator = FakeTerminalAppActivator()
    let session = Self.session(clients: [Local.client()])
    let harness = try Self.harness(session, table: table, activator: activator)
    defer { harness.cleanUp() }
    let result = await harness.backend.attach(
      AttachTarget(host: AttachTestSupport.host, session: session))
    let attachment = LocalAttachment(
      app: Local.terminalApp, clientPID: Local.clientPID, terminalPath: Local.terminalPath,
      isControlMode: false)
    #expect(result.state == .appFocused(app: Local.terminalApp))
    #expect(result.isFocused && result.isAttached && !result.isConfirmed)
    #expect(result.localAttachment == attachment && result.appActivation == .activated)
    #expect(result.plainWindow == nil && result.plainClient == nil)
    #expect(result.plainWindowFocus == nil && result.failure == nil)
    #expect(activator.requests == [Local.terminalBundle])
    #expect(harness.windows.opens.isEmpty && harness.windows.focuses.isEmpty)
    #expect(harness.taken.isEmpty)
    #expect(try harness.files().isEmpty)
    #expect(harness.runner.requests.isEmpty && harness.discovery.calls == 1)
    #expect(table.lookups == [400, 300, 200, 100])
    #expect(harness.log.states == [.requested, .appFocused(app: Local.terminalApp)])
    #expect(await harness.backend.state(of: session.key) == .appFocused(app: Local.terminalApp))
    #expect(await harness.backend.attachment(of: session.key) == nil)
  } // End of func focusesTheAppInsteadOfOpening()

  /// Another app than the backend's counts (Terminal's client for Ghostty's backend), and so do
  /// iTerm2's control-mode clients (no D16 index beside the plain backend): the first attributed
  /// client in the session's order is the one focused.
  @Test func anotherAppAndITerm2sControlClientsCount() async throws {
    let server = Local.jobServerFolder + "/iTermServer-3.7.7"
    let table = Local.table(
      Local.terminalChain() + [
        Local.process(150, parent: 1, start: 50, path: server),
        Local.process(450, parent: 150, start: 120, tty: Local.otherDevice, path: "/bin/zsh"),
        ProcessTableEntry(
          pid: 500, parentPID: 450, startTime: Local.start(300),
          controllingTerminal: Local.otherDevice),
      ])
    let activator = FakeTerminalAppActivator()
    let iTerm2Client = Local.client(pid: 500, controlMode: true, tty: Local.otherTerminalPath)
    let first = Self.session(clients: [Local.client(pid: 999), iTerm2Client, Local.client()])
    let harness = try Self.harness(
      first, table: table, activator: activator, loaded: try Support.ghostty())
    defer { harness.cleanUp() }
    let result = await harness.backend.attach(
      AttachTarget(host: AttachTestSupport.host, session: first))
    #expect(result.state == .appFocused(app: .iTerm2()))
    #expect(result.localAttachment?.isControlMode == true)
    #expect(activator.requests == [LocalTerminalApp.iTerm2BundleIdentifier])
    #expect(harness.windows.opens.isEmpty)

    let second = Self.session(clients: [Local.client()])
    harness.discovery.setStatus(.ok([second]))
    let again = await harness.backend.attach(
      AttachTarget(host: AttachTestSupport.host, session: second))
    #expect(again.state == .appFocused(app: Local.terminalApp))
    #expect(activator.requests.last == Local.terminalBundle)
  } // End of func anotherAppAndITerm2sControlClientsCount()

  /// macOS refusing the activation, or the app no longer running, still ends `appFocused` with
  /// the outcome recorded: nothing is opened and nothing launched.
  @Test(arguments: [TerminalAppActivation.refused, .notRunning])
  func activationOutcomesNeverOpen(answer: TerminalAppActivation) async throws {
    let activator = FakeTerminalAppActivator(answer: answer)
    let session = Self.session(clients: [Local.client()])
    let harness = try Self.harness(
      session, table: Local.table(Local.terminalChain()), activator: activator)
    defer { harness.cleanUp() }
    let result = await harness.backend.attach(
      AttachTarget(host: AttachTestSupport.host, session: session))
    #expect(result.state == .appFocused(app: Local.terminalApp))
    #expect(result.appActivation == answer && result.failure == nil)
    #expect(harness.windows.opens.isEmpty && harness.taken.isEmpty)
    #expect(activator.requests == [Local.terminalBundle])
  } // End of func activationOutcomesNeverOpen(answer:)

  /// The backend's own live record is focused first (`plainFocused`), the table never read,
  /// even when its client would be traced to Terminal.
  @Test func theOwnRecordComesFirst() async throws {
    let table = Local.table([
      Local.process(100, parent: 1, start: 10, bundle: Local.terminalBundle),
      ProcessTableEntry(
        pid: Support.childPID, parentPID: 100, startTime: Local.start(100),
        controllingTerminal: Local.device),
    ])
    let activator = FakeTerminalAppActivator()
    let quiet = Self.session(clients: [])
    let harness = try Self.harness(
      quiet, table: table, activator: activator,
      answer: { kind, _ in
        kind == .presence
          ? Support.output(PlainClientPresence.presentMarker + "\n")
          : Support.listing(Support.listingLine())
      })
    defer { harness.cleanUp() }
    let first = await harness.backend.attach(
      AttachTarget(host: AttachTestSupport.host, session: quiet))
    #expect(first.isConfirmed)
    let client = try #require(first.plainClient)
    let attached = Self.session(clients: [
      Local.client(pid: Support.childPID, tty: Support.terminalPath, created: Support.clientCreated)
    ])
    harness.discovery.setStatus(.ok([attached]))
    let focused = await harness.backend.attach(
      AttachTarget(host: AttachTestSupport.host, session: attached))
    #expect(focused.state == .plainFocused(client: client))
    #expect(table.lookups.isEmpty && activator.requests.isEmpty)
    #expect(harness.windows.opens.count == 1)
  } // End of func theOwnRecordComesFirst()

  /// Unmapped clients (a client whose process is gone, one with no terminal) and a table that
  /// cannot be read never block: the attach opens its window and confirms as before.
  @Test(arguments: [false, true])
  func unmappedClientsNeverBlock(unreadable: Bool) async throws {
    let table = Local.table([])
    if unreadable { table.set(Local.clientPID, .unreadable) }
    let activator = FakeTerminalAppActivator()
    let session = Self.session(clients: [Local.client(), Local.client(pid: 401, tty: nil)])
    let harness = try Self.harness(session, table: table, activator: activator)
    defer { harness.cleanUp() }
    let result = await harness.backend.attach(
      AttachTarget(host: AttachTestSupport.host, session: session))
    #expect(result.isConfirmed && result.localAttachment == nil && result.appActivation == nil)
    #expect(harness.windows.opens.count == 1 && activator.requests.isEmpty)
    #expect(table.lookups == [Local.clientPID], "read once, for the one complete client")
  } // End of func unmappedClientsNeverBlock(unreadable:)

  /// A move here attaches with `-d` whatever is attached: no ancestry check, a window opened.
  @Test func moveHereIsUnchanged() async throws {
    let table = Local.table(Local.terminalChain())
    let activator = FakeTerminalAppActivator()
    let session = Self.session(clients: [Local.client()])
    let harness = try Self.harness(session, table: table, activator: activator)
    defer { harness.cleanUp() }
    let target = AttachTarget(host: AttachTestSupport.host, session: session)
    let result = await harness.backend.moveHere(
      target, confirmation: .detachOtherClients(of: target.key))
    #expect(result.isConfirmed)
    #expect(harness.taken.first?.detachesOtherClients == true)
    #expect(table.lookups.isEmpty && activator.requests.isEmpty)
  } // End of func moveHereIsUnchanged()

  /// An SSH host's clients are never attributed: the attach opens and confirms by the token,
  /// the table never read.
  @Test func sshHostsAreNeverAttributed() async throws {
    let host = Support.remoteHost
    let table = Local.table(Local.terminalChain())
    let activator = FakeTerminalAppActivator()
    let session = Self.session(on: host, clients: [Local.client()])
    let harness = try Self.harness(
      session, table: table, activator: activator,
      answer: { _, _ in Support.remoteAnswer([(true, Support.remoteClient)]) })
    defer { harness.cleanUp() }
    harness.report = { Support.report(for: $0, terminalPath: nil) }
    let result = await harness.backend.attach(AttachTarget(host: host, session: session))
    #expect(result.isConfirmed && harness.windows.opens.count == 1)
    #expect(table.lookups.isEmpty && activator.requests.isEmpty)
  } // End of func sshHostsAreNeverAttributed()

  /// An `.app` handle: the plain backend and iTerm2's both activate the running app through
  /// their activator (outcome as answered), sending nothing to iTerm2, the window layer or tmux.
  @Test func focusingAnAppHandle() async throws {
    let activator = FakeTerminalAppActivator(answer: .refused)
    let harness = try Self.harness(
      Self.session(clients: []), table: Local.table([]), activator: activator)
    defer { harness.cleanUp() }
    #expect(await harness.backend.focus(.app(Local.terminalApp)) == .appActivation(.refused))
    #expect(activator.requests == [Local.terminalBundle])
    #expect(harness.windows.focuses.isEmpty && harness.runner.requests.isEmpty)

    let coordinator = AttachCoordinatorTests.harness()
    let iTerm2 = ITerm2TerminalBackend(
      coordinator: coordinator.coordinator, appActivator: activator)
    activator.answer = .notRunning
    #expect(await iTerm2.focus(.app(.iTerm2())) == .appActivation(.notRunning))
    #expect(activator.requests.last == LocalTerminalApp.iTerm2BundleIdentifier)
    #expect(await coordinator.iTerm2.calls.isEmpty && coordinator.discovery.calls == 0)
  } // End of func focusingAnAppHandle()

  /// With no activator given, the real one is used: for an app nobody runs it answers
  /// `notRunning` and launches nothing.
  @Test func theRealActivatorNeverLaunches() async throws {
    let identifier = "test.muxfinder.no-such-terminal-app"
    let app = try #require(LocalTerminalApp(bundleIdentifier: identifier, definitionIDs: ["x"]))
    #expect(await RunningApplicationActivator.activate(app, with: nil) == .notRunning)
    #expect(NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty)
  }
} // End of struct PlainTerminalBackendOpenHereTests
