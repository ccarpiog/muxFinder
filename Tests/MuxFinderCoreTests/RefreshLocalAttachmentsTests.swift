import Foundation
import Testing

@testable import MuxFinderCore

/// The refresh engine's optional local client attributor (PLAN.md D38, Phase I-12c2): without
/// one nothing changes; with one, This Mac's snapshot sessions carry their clients traced to a
/// terminal app (iTerm2's control-mode clients left to D16's index when one is configured), an
/// SSH host's never. Fakes only: a scripted prober, a fake index and a fake process table.
@Suite("Refresh: open on this Mac")
struct RefreshLocalAttachmentsTests {
  /// Shorthand.
  typealias Support = RefreshTestSupport
  /// Shorthand.
  typealias Local = LocalClientSupport

  /// A table where the client pid 400 runs in Terminal and pid 500 (a control-mode client) under
  /// iTerm2's job server, both on their own terminals.
  static func table() -> FakeProcessTable {
    let server = Local.jobServerFolder + "/iTermServer-3.7.7"
    return FakeProcessTable(
      Local.terminalChain() + [
        Local.process(150, parent: 1, start: 50, path: server),
        Local.process(450, parent: 150, start: 120, tty: Local.otherDevice, path: "/bin/zsh"),
        ProcessTableEntry(
          pid: 500, parentPID: 450, startTime: Local.start(300),
          controllingTerminal: Local.otherDevice),
      ],
      terminals: [Local.terminalPath: Local.device, Local.otherTerminalPath: Local.otherDevice])
  } // End of static func table()

  /// The session `$1` on `host` with Terminal's plain client and iTerm2's control client.
  static func session(on host: HostConfig) -> DiscoveredSession {
    var session = Support.session(on: host)
    session.clients = [
      Local.client(),
      Local.client(pid: 500, controlMode: true, tty: Local.otherTerminalPath),
    ]
    return session
  }

  /// The attachment of Terminal's client.
  static let terminalAttachment = LocalAttachment(
    app: Local.terminalApp, clientPID: 400, terminalPath: Local.terminalPath,
    isControlMode: false)
  /// The attachment of iTerm2's control client.
  static let iTerm2Attachment = LocalAttachment(
    app: .iTerm2(), clientPID: 500, terminalPath: Local.otherTerminalPath, isControlMode: true)

  /// The engine's state after one `refreshOnce` over `hosts`.
  static func refreshed(
    _ hosts: [HostConfig],
    attributor: (any LocalClientAttributing)?,
    index: FakeAttachmentIndex? = nil
  ) async -> RefreshState {
    let prober = ScriptedProber()
    for host in hosts { prober.setAnswer(.ok([session(on: host)]), for: host.id) }
    let coordinator = RefreshCoordinator(
      hosts: Support.list(hosts), discovery: prober, attachmentIndex: index,
      localClients: attributor, clock: GatedAttachClock())
    let state = await coordinator.refreshOnce()
    await coordinator.stop()
    return state
  } // End of static func refreshed(_:attributor:index:)

  /// Without an attributor (the default) no session carries local attachments, as before.
  @Test func withoutAnAttributorNothingChanges() async {
    let mac = Support.thisMac()
    let state = await Self.refreshed([mac], attributor: nil)
    let sessions = state.snapshot(of: mac.id)?.sessions ?? []
    #expect(sessions.map(\.key) == [Self.session(on: mac).key])
    #expect(sessions.allSatisfy { $0.localAttachments.isEmpty && $0.attachments.isEmpty })
    #expect(sessions.first?.discovered == Self.session(on: mac))
  }

  /// With one and no index, This Mac's session carries both clients (iTerm2's control-mode one
  /// too); the SSH host's same clients are never attributed and its table is never read.
  @Test func withAnAttributorThisMacsSessionsCarryTheirApps() async {
    let mac = Support.thisMac()
    let remote = Support.sshHost("host-a")
    let table = Self.table()
    let attributor = LocalClientAttributor(
      table: table, definitions: Local.builtIns(),
      iTerm2JobServerDirectory: Local.jobServerFolder)
    let state = await Self.refreshed([mac, remote], attributor: attributor)
    #expect(
      state.snapshot(of: mac.id)?.sessions.first?.localAttachments
        == [Self.terminalAttachment, Self.iTerm2Attachment])
    #expect(state.snapshot(of: remote.id)?.sessions.first?.localAttachments == [])
    #expect(state.snapshot(of: remote.id)?.isLive == true)
    #expect(table.lookups.filter { $0 == 400 || $0 == 500 }.count == 2, "one walk per client")
  } // End of func withAnAttributorThisMacsSessionsCarryTheirApps()

  /// With an index configured (iTerm2 chosen), iTerm2's control-mode client is left to it.
  @Test func withAnIndexITerm2sControlClientsAreLeftToIt() async {
    let mac = Support.thisMac()
    let attributor = LocalClientAttributor(
      table: Self.table(), definitions: Local.builtIns(),
      iTerm2JobServerDirectory: Local.jobServerFolder)
    let state = await Self.refreshed(
      [mac], attributor: attributor, index: FakeAttachmentIndex(.fail(.notRunning)))
    #expect(
      state.snapshot(of: mac.id)?.sessions.first?.localAttachments == [Self.terminalAttachment])
  }
} // End of struct RefreshLocalAttachmentsTests
