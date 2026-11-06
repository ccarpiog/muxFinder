import Foundation
import MuxFinderCore

/// `muxfinder-probe local-clients`: discovers This Mac once and traces every tmux client to the
/// terminal app its process descends from (PLAN.md D38, Phase I-12c2; `LocalClientAttributor`
/// over `SystemProcessTable`), printing JSON: per client its session id (never the session's
/// name), whether it is in control mode, and the app or why it is unmapped; then the counts.
///
/// Read-only: discovery's static probe, then the process table by pid (`sysctl`,
/// `proc_pidpath`, `NSRunningApplication(processIdentifier:)`). It contacts no iTerm2, sends no
/// Apple event, launches and activates nothing, writes nothing; `--help` contacts nothing. No
/// pid, terminal path or session name is printed.
enum LocalClientsCommand {
  /// Usage lines for this subcommand.
  static let usage = """
      local-clients [--builtin-directory <dir>] [--user-directory <dir>]
          Discover This Mac's tmux sessions once and trace each client to the terminal app its
          process descends from (read-only: parent, start time and controlling terminal by
          pid, the executable path, a registered app's bundle identifier), as JSON: per client
          its session id (never the name), control mode, and the app (bundle identifier and
          definition ids) or why it is unmapped; then the counts per app and per reason, and
          the local attachments with and without D16's index in use. Definitions load as for
          terminals list. Contacts no iTerm2, sends no Apple event, launches, activates and
          writes nothing.
    """

  /// Runs the subcommand with the arguments after `local-clients` and returns the exit status.
  static func run(_ arguments: [String]) async -> Int32 {
    if arguments.count == 1, ["--help", "-h", "help"].contains(arguments[0]) {
      print("usage:\n\(usage)")
      return 0
    }
    guard let folders = TerminalsCommand.parseListOptions(arguments) else {
      printError(
        "muxfinder-probe: local-clients takes --builtin-directory <dir> and "
          + "--user-directory <dir>, each at most once\n\nusage:\n\(usage)")
      return EX_USAGE
    }
    let catalog = TerminalDefinitionLoader(
      builtInDirectory: folders.builtIn, userDirectory: folders.user
    ).load()
    let host = HostConfig(displayName: "This Mac", mode: .local)
    let result: DiscoveryResult
    do {
      result = try await DiscoveryProbe().discover(host)
    } catch {
      printError("muxfinder-probe: \(error)")
      return EX_SOFTWARE
    }
    let attributor = LocalClientAttributor(definitions: catalog.definitions)
    return HostsCommand.printJSON(output(for: result, attributor: attributor, catalog: catalog))
  } // End of func run(_:)

  /// The JSON document for `result`, every client attributed once.
  static func output(
    for result: DiscoveryResult,
    attributor: LocalClientAttributor,
    catalog: TerminalDefinitionCatalog
  ) -> Output {
    var sessions: [DiscoveredSession] = []
    if case .ok(let listed) = result.status { sessions = listed }
    var clients: [ClientEntry] = []
    var byApp: [String: Int] = [:]
    var unmapped = Dictionary(
      uniqueKeysWithValues: LocalClientUnmappedReason.allCases.map { ($0.rawValue, 0) })
    var withoutIndex = 0
    var withIndex = 0
    for session in sessions {
      let attributed = session.clients.map { (client: $0, attribution: attributor.attribute($0)) }
      for (client, attribution) in attributed {
        clients.append(ClientEntry(session.key.sessionID, client, attribution))
        switch attribution {
        case .app(let app): byApp[app.bundleIdentifier, default: 0] += 1
        case .unmapped(let reason): unmapped[reason.rawValue, default: 0] += 1
        }
      } // End of loop over the session's clients
      withoutIndex += LocalAttachment.counted(attributed, indexInUse: false).count
      withIndex += LocalAttachment.counted(attributed, indexInUse: true).count
    } // End of loop over the sessions
    return Output(
      status: result.status.kind,
      definitions: catalog.definitions.map(\.definition.id),
      definitionProblems: catalog.problems.count,
      iTerm2JobServerFolderKnown: attributor.iTerm2JobServerDirectory != nil,
      sessions: sessions.count,
      clients: clients,
      counts: Counts(
        clients: clients.count, attributed: byApp.values.reduce(0, +), byApp: byApp,
        unmapped: unmapped, localAttachmentsWithoutIndex: withoutIndex,
        localAttachmentsWithIndex: withIndex))
  } // End of static func output(for:attributor:catalog:)

  /// The top-level JSON object.
  struct Output: Encodable {
    /// `HostStatus.kind` of This Mac's discovery.
    let status: String
    /// The ids of the loaded definitions, in loader order.
    let definitions: [String]
    /// How many definition files or folders could not be used.
    let definitionProblems: Int
    /// Whether iTerm2's job server folder (of the real home) is known.
    let iTerm2JobServerFolderKnown: Bool
    /// How many sessions discovery listed.
    let sessions: Int
    /// Every client, session by session.
    let clients: [ClientEntry]
    /// The counts.
    let counts: Counts
  }

  /// One client in the JSON: no pid, no terminal path, no session name.
  struct ClientEntry: Encodable {
    /// The session's id (`$3`).
    let sessionID: String
    /// Whether the client is in control mode.
    let controlMode: Bool
    /// Whether discovery gave its terminal path and creation time.
    let hasTerminalAndCreationTime: Bool
    /// The app, when attributed.
    let app: AppEntry?
    /// Why not, when unmapped.
    let unmapped: String?

    /// The entry for `client` of the session `sessionID`.
    init(
      _ sessionID: TmuxSessionID,
      _ client: ClientSummary,
      _ attribution: LocalClientAttribution
    ) {
      self.sessionID = sessionID.rawValue
      controlMode = client.isControlMode
      hasTerminalAndCreationTime = client.terminalPath != nil && client.createdAt != nil
      switch attribution {
      case .app(let found):
        app = AppEntry(bundleIdentifier: found.bundleIdentifier, definitionIDs: found.definitionIDs)
        unmapped = nil
      case .unmapped(let reason):
        app = nil
        unmapped = reason.rawValue
      }
    } // End of init(_:_:_:)
  } // End of struct ClientEntry

  /// An attributed app in the JSON.
  struct AppEntry: Encodable {
    /// Its bundle identifier.
    let bundleIdentifier: String
    /// The loaded definitions sharing it, in loader order.
    let definitionIDs: [String]
  }

  /// The counts in the JSON.
  struct Counts: Encodable {
    /// Every client listed.
    let clients: Int
    /// The clients traced to an app.
    let attributed: Int
    /// Attributed clients per app's bundle identifier.
    let byApp: [String: Int]
    /// Unmapped clients per reason (every reason, zero included).
    let unmapped: [String: Int]
    /// The local attachments without D16's index (iTerm2 not chosen): every attributed client.
    let localAttachmentsWithoutIndex: Int
    /// The local attachments with D16's index in use (iTerm2 chosen): iTerm2's control-mode
    /// clients left to the index.
    let localAttachmentsWithIndex: Int
  }
} // End of enum LocalClientsCommand
