import Foundation
import MuxFinderCore

/// `muxfinder-probe refresh --once`: one round of the refresh engine (PLAN.md D20) over the
/// saved host list, printed as JSON.
///
/// The host list is loaded through `HostStore.load()`, which never writes (as `hosts show`).
/// Every enabled host is refreshed once through a real `RefreshCoordinator` (never started, so
/// nothing is scheduled), whose discovery is the real `DiscoveryProbe`: This Mac runs tmux
/// directly, SSH hosts run noninteractive ssh (D6). Without `--attachments` iTerm2 is never
/// contacted. With it, one attachment check follows the round: the index sends the read-only
/// identity `display-message` to every tmux connection in iTerm2, the user's included (D16).
enum RefreshCommand {
  /// Usage lines for this subcommand.
  static let usage = """
      refresh --once [--config <path>] [--attachments]
          Load the host list without writing anything, refresh every enabled host once through
          the refresh engine and print the host snapshots as JSON. No iTerm2 window opens.
          --config       Read this host list instead of
                         ~/Library/Application Support/muxFinder/hosts.json (as hosts show).
          --attachments  Then check which sessions are open in iTerm2 on this Mac. This sends
                         every iTerm2 tmux connection, yours included, a read-only
                         display-message. Without it iTerm2 is not contacted.
    """

  /// Parsed command-line options.
  struct Options {
    /// The host list file, or `nil` for the default one.
    var config: URL?
    /// Whether to run the attachment check.
    var attachments = false
  }

  /// Runs the subcommand with the arguments after `refresh` and returns the exit status: 0
  /// once the round ran (each host's outcome is in the JSON), `EX_USAGE` for bad arguments,
  /// `EX_SOFTWARE` when the host list cannot be loaded or the output encoded.
  static func run(_ arguments: [String]) async -> Int32 {
    guard let options = parse(arguments) else {
      printError("muxfinder-probe: refresh needs --once\n\nusage:\n\(usage)")
      return EX_USAGE
    }
    let store = options.config.map { HostStore(fileURL: $0) } ?? HostStore()
    let loaded: HostStoreLoadResult
    do {
      loaded = try await store.load()
    } catch {
      printError("muxfinder-probe: \(error.localizedDescription)")
      return EX_SOFTWARE
    }
    let client = options.attachments ? ITerm2APIClient() : nil
    let coordinator = RefreshCoordinator(
      hosts: loaded.hosts,
      attachmentIndex: client.map { AttachmentIndex(iTerm2: $0) }
    )
    let state = await coordinator.refreshOnce(includeAttachments: options.attachments)
    await coordinator.stop()
    await client?.disconnect()
    return printJSON(Output(state, loaded: loaded, file: store.fileURL))
  } // End of func run(_:)

  /// Parses the arguments; `nil` when they are not valid.
  static func parse(_ arguments: [String]) -> Options? {
    var options = Options()
    var once = false
    var remaining = arguments[...]
    while let argument = remaining.popFirst() {
      switch argument {
      case "--once":
        once = true
      case "--attachments":
        options.attachments = true
      case "--config":
        guard let path = remaining.popFirst(), !path.isEmpty else { return nil }
        options.config = URL(fileURLWithPath: path).standardizedFileURL
      default:
        return nil
      }
    } // End of loop over arguments
    return once ? options : nil
  } // End of func parse(_:)

  /// Prints `value` as pretty, sorted JSON with ISO 8601 dates and returns 0, or
  /// `EX_SOFTWARE` if it cannot be encoded.
  static func printJSON<Value: Encodable>(_ value: Value) -> Int32 {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(value) else {
      printError("muxfinder-probe: could not encode the output")
      return EX_SOFTWARE
    }
    print(String(decoding: data, as: UTF8.self))
    return 0
  } // End of func printJSON(_:)

  /// The JSON document.
  struct Output: Encodable {
    /// The host list file that was read.
    let file: String
    /// Its load state: `saved`, `notSavedYet` or `invalid`.
    let state: String
    /// The problem's code when `invalid`.
    let problem: String?
    /// The engine's configuration revision.
    let configRevision: Int
    /// The attachment check.
    let attachments: AttachmentsOutput
    /// One entry per enabled host, in list order.
    let hosts: [HostOutput]
    /// How many sessions all hosts reported.
    let sessionCount: Int

    /// The output for `state`, after loading `loaded` from `file`.
    init(_ state: RefreshState, loaded: HostStoreLoadResult, file: URL) {
      self.file = file.path(percentEncoded: false)
      switch loaded.state {
      case .saved:
        self.state = "saved"
        problem = nil
      case .notSavedYet:
        self.state = "notSavedYet"
        problem = nil
      case .invalid(let found):
        self.state = "invalid"
        problem = found.code
      }
      configRevision = state.configRevision
      attachments = AttachmentsOutput(state.attachmentCheck)
      hosts = state.hosts.map(HostOutput.init)
      sessionCount = state.sessions.count
    } // End of init(_:loaded:file:)
  }

  /// The attachment check: `state` (`notChecked`, `checked`, `iTermNotRunning`, `failed`), the
  /// counts when checked and the error's kind when failed.
  struct AttachmentsOutput: Encodable {
    /// `AttachmentCheck.kind`.
    let state: String
    /// When it ran.
    let checkedAt: Date?
    /// Mapped and unmapped connections, when checked.
    let counts: AttachmentSnapshot.Counts?
    /// The listing error's kind, when failed.
    let error: String?

    /// Converts `check`.
    init(_ check: AttachmentCheck) {
      state = check.kind
      switch check {
      case .notChecked:
        (checkedAt, counts, error) = (nil, nil, nil)
      case .checked(let date, let found):
        (checkedAt, counts, error) = (date, found, nil)
      case .iTermNotRunning(let date):
        (checkedAt, counts, error) = (date, nil, nil)
      case .failed(let date, let failure):
        (checkedAt, counts, error) = (date, nil, failure?.kind ?? "unexpected")
      }
    } // End of init(_:)
  }

  /// One host's snapshot.
  struct HostOutput: Encodable {
    /// `HostConfig.id`.
    let id: UUID
    /// The display name.
    let displayName: String
    /// `local` or `ssh`.
    let mode: String
    /// The SSH destination, for `ssh`.
    let destination: String?
    /// `notChecked`, `live` or `stale`.
    let freshness: String
    /// How the last attempt ended.
    let outcome: OutcomeOutput?
    /// When the last attempt finished.
    let lastAttempt: Date?
    /// When the last successful attempt finished.
    let lastSuccess: Date?
    /// Failures since the last success.
    let consecutiveFailures: Int
    /// `uname -n` from the last success.
    let nodeName: String?
    /// The sessions (live, or the last success's when stale).
    let sessions: [SessionOutput]

    /// Converts `snapshot`.
    init(_ snapshot: HostSnapshot) {
      id = snapshot.host.id
      displayName = snapshot.host.displayName
      mode = snapshot.host.mode.rawValue
      destination = snapshot.host.mode == .ssh ? snapshot.host.sshDestination : nil
      freshness = snapshot.freshness.rawValue
      outcome = snapshot.lastOutcome.map(OutcomeOutput.init)
      lastAttempt = snapshot.lastAttempt
      lastSuccess = snapshot.lastSuccess
      consecutiveFailures = snapshot.consecutiveFailures
      nodeName = snapshot.nodeName
      sessions = snapshot.sessions.map(SessionOutput.init)
    } // End of init(_:)
  }

  /// How an attempt ended: `kind` (`ok`, `noServer` or the failure's), plus the reason or
  /// message when the failure has one.
  struct OutcomeOutput: Encodable {
    /// `HostSnapshot.Outcome.kind`.
    let kind: String
    /// The unreachable reason or host-key problem.
    let reason: String?
    /// The probe error message.
    let message: String?

    /// Converts `outcome`.
    init(_ outcome: HostSnapshot.Outcome) {
      kind = outcome.kind
      switch outcome {
      case .failed(.unreachable(let why)):
        (reason, message) = (why.rawValue, nil)
      case .failed(.hostKeyProblem(let problem)):
        (reason, message) = (problem.rawValue, nil)
      case .failed(.probeError(let text)):
        (reason, message) = (nil, text)
      default:
        (reason, message) = (nil, nil)
      }
    } // End of init(_:)
  }

  /// One session.
  struct SessionOutput: Encodable {
    /// The session's identity (host, server, session id).
    let key: SessionKey
    /// The session name.
    let name: String
    /// Windows.
    let windowCount: Int
    /// Attached clients, as tmux counts them.
    let attachedClientCount: Int
    /// The session's start folder, when discovery reported a usable one (PLAN.md D31; a stale
    /// host keeps its last success's).
    let startDirectory: String?
    /// The iTerm2 tmux connections on this Mac showing it (from `--attachments`).
    let iTerm2Connections: [ConnectionOutput]

    /// Converts `session`.
    init(_ session: HostSnapshot.Session) {
      key = session.key
      name = session.discovered.name
      windowCount = session.discovered.windowCount
      attachedClientCount = session.discovered.attachedClientCount
      startDirectory = session.discovered.startDirectory
      iTerm2Connections = session.attachments.map {
        ConnectionOutput(connectionID: $0.connectionID, owningSessionID: $0.owningSessionID)
      }
    } // End of init(_:)
  }

  /// One iTerm2 tmux connection.
  struct ConnectionOutput: Encodable {
    /// The connection id.
    let connectionID: String
    /// The iTerm2 session running its `tmux -CC` client.
    let owningSessionID: String
  }
}
