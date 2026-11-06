import Foundation
import Testing

@testable import MuxFinderCore

/// Synthetic process tables and definitions for the open-on-this-Mac tests (PLAN.md D38, Phase
/// I-12c2). Every pid, device and path is made up.
enum LocalClientSupport {
  /// The job server folder the tests inject (never the real home's).
  static let jobServerFolder = "/Users/fixture/Library/Application Support/iTerm2"
  /// The client's terminal.
  static let terminalPath = "/dev/ttys003"
  /// Its device number.
  static let device: Int32 = 0x1000_0003
  /// Another terminal and its device.
  static let otherTerminalPath = "/dev/ttys009"
  /// The other terminal's device.
  static let otherDevice: Int32 = 0x1000_0009
  /// When tmux created the client.
  static let created: Int64 = 1_792_600_300
  /// The client's pid.
  static let clientPID: Int32 = 400
  /// Terminal's bundle identifier.
  static let terminalBundle = "com.apple.Terminal"
  /// Ghostty's bundle identifier.
  static let ghosttyBundle = "com.mitchellh.ghostty"

  /// A start time `seconds` after 1_792_600_000.
  static func start(_ seconds: Int64, _ microseconds: Int32 = 0) -> ProcessStartTime {
    ProcessStartTime(seconds: 1_792_600_000 + seconds, microseconds: microseconds)
  }

  /// A process entry.
  static func process(
    _ pid: Int32,
    parent: Int32,
    start seconds: Int64,
    tty: Int32? = nil,
    path: String? = nil,
    bundle: String? = nil
  ) -> ProcessTableEntry {
    ProcessTableEntry(
      pid: pid, parentPID: parent, startTime: start(seconds), controllingTerminal: tty,
      executablePath: path, bundleIdentifier: bundle)
  } // End of static func process(_:parent:start:tty:path:bundle:)

  /// The tmux client process (pid 400, under the zsh `parent`), on the terminal, started half a
  /// second after `created`.
  static func clientProcess(parent: Int32 = 300, tty: Int32? = device) -> ProcessTableEntry {
    ProcessTableEntry(
      pid: clientPID, parentPID: parent, startTime: start(300, 500_000),
      controllingTerminal: tty, executablePath: "/opt/homebrew/bin/tmux")
  }

  /// The client discovery reports: pid 400 on the terminal, created at `created`.
  static func client(
    pid: Int32 = clientPID,
    controlMode: Bool = false,
    tty: String? = terminalPath,
    created: Int64? = created
  ) -> ClientSummary {
    ClientSummary(pid: pid, isControlMode: controlMode, terminalPath: tty, createdAt: created)
  }

  /// Terminal's chain: Terminal (100) → login (200) → zsh (300) → tmux client (400).
  static func terminalChain() -> [ProcessTableEntry] {
    [
      process(
        100, parent: 1, start: 10,
        path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
        bundle: terminalBundle),
      process(200, parent: 100, start: 100, tty: device, path: "/usr/bin/login"),
      process(300, parent: 200, start: 101, tty: device, path: "/bin/zsh"),
      clientProcess(),
    ]
  }

  /// A table of `entries` with the two terminals' devices.
  static func table(_ entries: [ProcessTableEntry]) -> FakeProcessTable {
    FakeProcessTable(entries, terminals: [terminalPath: device, otherTerminalPath: otherDevice])
  }

  /// The built-in definitions (Ghostty, Terminal), loaded as text.
  static func builtIns() -> [LoadedTerminalDefinition] {
    TerminalDefinitionTestSupport.load(builtIn: TerminalDefinitionTestSupport.builtInDirectory)
      .definitions
  }

  /// A user definition `id` for the app `bundle`, made from Terminal's built-in.
  static func definition(_ id: String, bundle: String) throws -> LoadedTerminalDefinition {
    let base = try #require(builtIns().first { $0.definition.id == "terminal" })
    let source = base.definition
    let definition = TerminalDefinition(
      id: id, displayName: "Fixture \(id)", bundleIdentifier: bundle,
      minimumVersion: source.minimumVersion, notes: nil, open: source.open, focus: source.focus,
      keepsMinimumLifetime: source.keepsMinimumLifetime)
    return LoadedTerminalDefinition(
      definition: definition, source: .user, fileName: "\(id).json", script: base.script)
  } // End of static func definition(_:bundle:)

  /// An attributor over `table` with `definitions` (the built-ins by default) and the injected
  /// job server folder.
  static func attributor(
    _ table: FakeProcessTable,
    definitions: [LoadedTerminalDefinition]? = nil
  ) -> LocalClientAttributor {
    LocalClientAttributor(
      table: table, definitions: definitions ?? builtIns(),
      iTerm2JobServerDirectory: jobServerFolder)
  }

  /// Terminal, as ancestry names it with the built-ins.
  static let terminalApp = LocalTerminalApp(
    bundleIdentifier: terminalBundle, definitionIDs: ["terminal"])!

  /// The session `$3` on `host` with `clients`.
  static func session(
    on host: HostConfig,
    id: String = "$3",
    clients: [ClientSummary]
  ) -> DiscoveredSession {
    DiscoveredSession(
      key: SessionKey(
        hostID: host.id, server: AttachTestSupport.server, sessionID: TmuxSessionID(id)!),
      name: "fixture-session", createdAt: 1_792_600_001, windowCount: 1, attachedClientCount: 1,
      lastActivityAt: 1_792_600_050, clients: clients)
  }
} // End of enum LocalClientSupport

/// Process ancestry over a fake table (PLAN.md D38, Phase I-12c2): which terminal app a tmux
/// client on This Mac runs in, pid reuse refused, the walk bounded, and the per-session rule
/// with and without D16's index. Nothing reads the real process table.
@Suite("Open on this Mac: process ancestry")
struct LocalClientAttributionTests {
  /// Shorthand.
  typealias Support = LocalClientSupport

  /// Terminal's chain names Terminal, with its definition id; the walk read the client and its
  /// three ancestors once each.
  @Test func terminalsChainNamesTerminal() {
    let table = Support.table(Support.terminalChain())
    let attribution = Support.attributor(table).attribute(Support.client())
    #expect(attribution == .app(Support.terminalApp))
    #expect(attribution.app?.terminal == .plain(definitionID: "terminal"))
    #expect(attribution.app?.isITerm2 == false)
    #expect(table.lookups == [400, 300, 200, 100])
  }

  /// An app chain (Ghostty runs the shell directly): the first ancestor whose bundle identifier
  /// is a definition's names it, compared without case.
  @Test func anAppChainNamesItsApp() {
    let table = Support.table([
      Support.process(100, parent: 1, start: 10, bundle: "COM.mitchellh.Ghostty"),
      Support.process(300, parent: 100, start: 100, tty: Support.device, path: "/bin/zsh"),
      Support.clientProcess(),
    ])
    let attribution = Support.attributor(table).attribute(Support.client())
    #expect(attribution.app?.definitionIDs == ["ghostty"])
    #expect(attribution.app?.bundleIdentifier == "COM.mitchellh.Ghostty")
  }

  /// iTerm2's job server under iTerm2, and under launchd after an iTerm2 restart, names iTerm2
  /// either way (needing no definition); one outside the job server folder, or in a subfolder
  /// of it, does not.
  @Test func iTerm2sJobServerNamesITerm2() {
    let server = Support.jobServerFolder + "/iTermServer-3.7.7"
    for parent: Int32 in [90, 1] {
      let table = Support.table([
        Support.process(
          90, parent: 1, start: 5, path: "/Applications/iTerm.app/Contents/MacOS/iTerm2",
          bundle: LocalTerminalApp.iTerm2BundleIdentifier),
        Support.process(150, parent: parent, start: 50, path: server),
        Support.process(200, parent: 150, start: 100, tty: Support.device, path: "/usr/bin/login"),
        Support.process(300, parent: 200, start: 101, tty: Support.device, path: "/bin/zsh"),
        Support.clientProcess(),
      ])
      let attribution = Support.attributor(table).attribute(Support.client(controlMode: true))
      #expect(attribution == .app(.iTerm2()), "job server's parent \(parent)")
      #expect(attribution.app?.terminal == .iterm2)
      #expect(table.lookups == [400, 300, 200, 150], "stops at the job server")
    } // End of loop over the job server's parents
    for path in ["/tmp/iTermServer-3.7.7", Support.jobServerFolder + "/old/iTermServer-3.7.7"] {
      let table = Support.table([
        Support.process(150, parent: 1, start: 50, path: path),
        Support.process(300, parent: 150, start: 101, tty: Support.device, path: "/bin/zsh"),
        Support.clientProcess(),
      ])
      #expect(
        Support.attributor(table).attribute(Support.client()) == .unmapped(.noTerminalAncestor))
    } // End of loop over paths that are not the job server
    let none = LocalClientAttributor(
      table: Support.table([
        Support.process(150, parent: 1, start: 50, path: server),
        Support.process(300, parent: 150, start: 101, tty: Support.device),
        Support.clientProcess(),
      ]),
      definitions: Support.builtIns(), iTerm2JobServerDirectory: nil)
    #expect(none.attribute(Support.client()) == .unmapped(.noTerminalAncestor))
  } // End of func iTerm2sJobServerNamesITerm2()

  /// A client nested in another tmux session (its shell under the tmux server, which runs under
  /// launchd) and one over ssh (under sshd) have no terminal ancestor.
  @Test func nestedTmuxAndSSHHaveNoTerminalAncestor() {
    let nested = Support.table([
      Support.process(250, parent: 1, start: 20, path: "/opt/homebrew/bin/tmux"),
      Support.process(300, parent: 250, start: 101, tty: Support.device, path: "/bin/zsh"),
      Support.clientProcess(),
    ])
    #expect(
      Support.attributor(nested).attribute(Support.client()) == .unmapped(.noTerminalAncestor))
    let ssh = Support.table([
      Support.process(120, parent: 1, start: 2, path: "/usr/sbin/sshd"),
      Support.process(200, parent: 120, start: 99, path: "/usr/libexec/sshd-session"),
      Support.process(300, parent: 200, start: 101, tty: Support.device, path: "/bin/zsh"),
      Support.clientProcess(),
    ])
    #expect(Support.attributor(ssh).attribute(Support.client()) == .unmapped(.noTerminalAncestor))
    #expect(ssh.lookups == [400, 300, 200, 120], "launchd itself is never read")
  } // End of func nestedTmuxAndSSHHaveNoTerminalAncestor()

  /// A cycle in the table stops the walk at the repeated pid.
  @Test func aCycleStopsTheWalk() {
    let table = Support.table([
      Support.process(200, parent: 300, start: 100),
      Support.process(300, parent: 200, start: 101),
      Support.clientProcess(),
    ])
    #expect(Support.attributor(table).attribute(Support.client()) == .unmapped(.noTerminalAncestor))
    #expect(table.lookups == [400, 300, 200])
  }

  /// The walk visits at most 64 parents: an app 64 steps up is found, 65 is too deep.
  @Test(arguments: [64, 65])
  func theWalkIsBounded(depth: Int) {
    var entries = [Support.clientProcess(parent: 1000)]
    for step in 0..<depth {
      let pid = Int32(1000 + step)
      let isTop = step == depth - 1
      entries.append(
        Support.process(
          pid, parent: isTop ? 1 : pid + 1, start: 100 - Int64(step),
          bundle: isTop ? Support.terminalBundle : nil))
    } // End of loop building the chain
    let table = Support.table(entries)
    let attribution = Support.attributor(table).attribute(Support.client())
    if depth <= LocalClientAttributor.maximumSteps {
      #expect(attribution == .app(Support.terminalApp))
    } else {
      #expect(attribution == .unmapped(.tooDeep))
    }
    #expect(table.lookups.count == min(depth, LocalClientAttributor.maximumSteps) + 1)
  } // End of func theWalkIsBounded(depth:)

  /// A process gone mid-walk, a table that cannot be read, and a parent that started after its
  /// child (its pid reused) end the walk unmapped.
  @Test func goneUnreadableAndReusedParents() {
    var chain = Support.terminalChain()
    let gone = Support.table(chain)
    gone.set(200, .gone)
    #expect(Support.attributor(gone).attribute(Support.client()) == .unmapped(.processGone))
    let unreadable = Support.table(chain)
    unreadable.set(300, .unreadable)
    #expect(Support.attributor(unreadable).attribute(Support.client()) == .unmapped(.unreadable))
    chain[1] = Support.process(200, parent: 100, start: 102, path: "/usr/bin/login")
    #expect(
      Support.attributor(Support.table(chain)).attribute(Support.client())
        == .unmapped(.processGone))
    let clientGone = Support.table([])
    #expect(Support.attributor(clientGone).attribute(Support.client()) == .unmapped(.processGone))
    let clientUnreadable = Support.table([])
    clientUnreadable.set(400, .unreadable)
    #expect(
      Support.attributor(clientUnreadable).attribute(Support.client()) == .unmapped(.unreadable))
  } // End of func goneUnreadableAndReusedParents()

  /// Pid reuse is refused on the client itself: another controlling terminal, none, a terminal
  /// path that is no device, or a start more than a second after tmux created the client.
  @Test func pidReuseIsRefused() {
    var chain = Support.terminalChain()
    let attribute = { (entries: [ProcessTableEntry], client: ClientSummary) in
      Support.attributor(Support.table(entries)).attribute(client)
    }
    #expect(
      attribute(chain, Support.client(tty: Support.otherTerminalPath))
        == .unmapped(.terminalMismatch))
    #expect(attribute(chain, Support.client(tty: "/dev/ttys777")) == .unmapped(.terminalMismatch))
    chain[3] = Support.clientProcess(tty: nil)
    #expect(attribute(chain, Support.client()) == .unmapped(.terminalMismatch))
    chain[3] = Support.clientProcess()
    // Started at created + 0.5 s: within the second of rounding; at + 1.5 s: refused.
    #expect(attribute(chain, Support.client(created: Support.created)).app != nil)
    #expect(
      attribute(chain, Support.client(created: Support.created - 1))
        == .unmapped(.startedAfterClient))
    var exact = chain
    exact[3].startTime = Support.start(301)
    #expect(attribute(exact, Support.client()).app != nil, "exactly a second later")
    exact[3].startTime = Support.start(301, 1)
    #expect(attribute(exact, Support.client()) == .unmapped(.startedAfterClient))
  } // End of func pidReuseIsRefused()

  /// A client with no usable terminal path or creation time is unmapped without a read.
  @Test func incompleteClientsAreUnmapped() {
    let table = Support.table(Support.terminalChain())
    let attributor = Support.attributor(table)
    #expect(attributor.attribute(Support.client(tty: nil)) == .unmapped(.incompleteClient))
    #expect(attributor.attribute(Support.client(created: nil)) == .unmapped(.incompleteClient))
    #expect(table.lookups.isEmpty)
  }

  /// Two definitions sharing a bundle identifier both name the app, in loader order; with no
  /// definition for it, Terminal names nothing.
  @Test func definitionsSharingABundleIdentifier() throws {
    let second = try Support.definition("aaa-terminal", bundle: "com.apple.terminal")
    let definitions = TerminalDefinitionLoaderOrder.sorted(Support.builtIns() + [second])
    let table = Support.table(Support.terminalChain())
    let attribution = Support.attributor(table, definitions: definitions)
      .attribute(Support.client())
    #expect(attribution.app?.definitionIDs == ["aaa-terminal", "terminal"])
    #expect(attribution.app?.terminal == .plain(definitionID: "aaa-terminal"))
    let ghosttyOnly = Support.builtIns().filter { $0.definition.id == "ghostty" }
    #expect(
      Support.attributor(Support.table(Support.terminalChain()), definitions: ghosttyOnly)
        .attribute(Support.client()) == .unmapped(.noTerminalAncestor))
  } // End of func definitionsSharingABundleIdentifier()

  /// The per-session rule: one attachment per attributed client in client order; with D16's
  /// index in use iTerm2's control-mode clients are left to it, its plain clients and other
  /// apps' clients counted; without it every attributed client counts.
  @Test func thePerSessionRule() {
    let iTerm2 = LocalTerminalApp.iTerm2()
    let attributed: [(client: ClientSummary, attribution: LocalClientAttribution)] = [
      (Support.client(pid: 1, controlMode: true), .app(iTerm2)),
      (Support.client(pid: 2, controlMode: false), .app(iTerm2)),
      (Support.client(pid: 3, controlMode: true), .app(Support.terminalApp)),
      (Support.client(pid: 4), .unmapped(.noTerminalAncestor)),
      (Support.client(pid: 5, tty: nil), .unmapped(.incompleteClient)),
    ]
    let without = LocalAttachment.counted(attributed, indexInUse: false)
    #expect(without.map(\.clientPID) == [1, 2, 3])
    #expect(
      without[0]
        == LocalAttachment(
          app: iTerm2, clientPID: 1, terminalPath: Support.terminalPath, isControlMode: true))
    let with = LocalAttachment.counted(attributed, indexInUse: true)
    #expect(with.map(\.clientPID) == [2, 3])
    #expect(with.map(\.app) == [iTerm2, Support.terminalApp])
  } // End of func thePerSessionRule()

  /// The attributor's sessions: This Mac's only, keyed by session, empty sessions left out; an
  /// SSH host's clients are never attributed (the table is not even read).
  @Test func onlyThisMacsClientsAreAttributed() {
    let table = Support.table(Support.terminalChain())
    let attributor = Support.attributor(table)
    let mac = HostConfig(displayName: "This Mac", mode: .local)
    let remote = HostConfig(displayName: "Remote", mode: .ssh, sshDestination: "remote-fixture")
    let session = Support.session(on: mac, clients: [Support.client()])
    let quiet = Support.session(on: mac, id: "$4", clients: [])
    let found = attributor.localAttachments(of: [session, quiet], on: mac, indexInUse: true)
    #expect(
      found
        == [
          session.key: [
            LocalAttachment(
              app: Support.terminalApp, clientPID: Support.clientPID,
              terminalPath: Support.terminalPath, isControlMode: false)
          ]
        ])
    let lookups = table.lookups.count
    let remoteSession = Support.session(on: remote, clients: [Support.client()])
    #expect(attributor.localAttachments(of: [remoteSession], on: remote, indexInUse: false).isEmpty)
    #expect(attributor.localAttachments(of: [remoteSession], on: mac, indexInUse: false).isEmpty)
    #expect(table.lookups.count == lookups, "no read for an SSH host's sessions")
  } // End of func onlyThisMacsClientsAreAttributed()

  /// The app type: iTerm2 needs no definition; another app needs at least one; the `.app`
  /// handle's terminal is the app's.
  @Test func theAppType() {
    #expect(LocalTerminalApp(bundleIdentifier: "com.example.editor", definitionIDs: []) == nil)
    #expect(LocalTerminalApp.iTerm2().terminal == .iterm2)
    #expect(TerminalAttachmentHandle.app(.iTerm2()).terminal == .iterm2)
    #expect(
      TerminalAttachmentHandle.app(Support.terminalApp).terminal
        == .plain(definitionID: "terminal"))
    #expect(TerminalFocusResult.appActivation(.refused).kind == "appActivation")
    #expect(AttachState.appFocused(app: Support.terminalApp).kind == "appFocused")
    #expect(LocalClientAttributor.withoutTrailingSlash("/a/b//") == "/a/b")
  }

  /// The real home's job server folder ends in `Library/Application Support/iTerm2`.
  @Test func theRealJobServerFolder() throws {
    let folder = try #require(LocalClientAttributor.realITerm2JobServerDirectory())
    #expect(folder.hasPrefix("/") && folder.hasSuffix("/Library/Application Support/iTerm2"))
  }
} // End of struct LocalClientAttributionTests

/// The loader's order (sorted by id), for definitions assembled in a test.
enum TerminalDefinitionLoaderOrder {
  /// `definitions` sorted by id, as `TerminalDefinitionLoader.load()` returns them.
  static func sorted(_ definitions: [LoadedTerminalDefinition]) -> [LoadedTerminalDefinition] {
    definitions.sorted { $0.definition.id < $1.definition.id }
  }
}
