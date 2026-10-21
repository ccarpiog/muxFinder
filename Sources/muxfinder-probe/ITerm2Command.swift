import Foundation
import MuxFinderCore

/// `muxfinder-probe iterm2 …`: read-only checks of iTerm2's native API.
///
/// None of these subcommands launches iTerm2, creates tabs, activates anything or sends tmux
/// commands: they call only `status()`, `listSessions()`, `listTmuxConnections()` and
/// `listProfiles(properties:guids:)`. Output is JSON on stdout; on failure a one-line error goes
/// to stderr and the exit status is non-zero. Session titles are never printed.
enum ITerm2Command {
  /// Usage lines for this subcommand group.
  static let usage = """
      iterm2 status [--socket <path>]
          Report whether iTerm2 runs, whether its API socket exists and whether an
          authenticated API connection succeeds.
      iterm2 list-sessions [--socket <path>]
          Print iTerm2's windows, tabs, split layouts and session ids (no titles).
      iterm2 list-connections [--socket <path>]
          Print iTerm2's tmux integration connections.
      iterm2 list-profiles [--socket <path>]
          Print every profile's GUID and name.
          --socket  Use this API socket instead of iTerm2's (test harness; a missing path
                    reports apiDisabled without requesting a cookie).
          All iterm2 subcommands are read-only and never launch iTerm2.
    """

  /// The subcommands.
  enum Action: String {
    /// `status`.
    case status
    /// `list-sessions`.
    case listSessions = "list-sessions"
    /// `list-connections`.
    case listConnections = "list-connections"
    /// `list-profiles`.
    case listProfiles = "list-profiles"
  }

  /// Runs the subcommand named by the first argument and returns the exit status.
  static func run(_ arguments: [String]) async -> Int32 {
    guard let name = arguments.first, let action = Action(rawValue: name) else {
      printError("muxfinder-probe: unknown iterm2 subcommand\n\nusage:\n\(usage)")
      return EX_USAGE
    }
    var configuration = ITerm2APIClient.Configuration()
    var remaining = arguments.dropFirst()
    while let argument = remaining.popFirst() {
      guard argument == "--socket", let path = remaining.popFirst() else {
        printError("muxfinder-probe: unknown option or missing value\n\nusage:\n\(usage)")
        return EX_USAGE
      }
      configuration.socketPath = path
    }
    let client = ITerm2APIClient(configuration: configuration)
    let status: Int32
    switch action {
    case .status:
      status = await runStatus(client, socketPath: configuration.socketPath)
    case .listSessions, .listConnections, .listProfiles:
      status = await runListing(action, client)
    }
    await client.disconnect()
    return status
  } // End of func run(_:)

  /// `status`: prints the status as JSON; exits non-zero unless a connection succeeded.
  static func runStatus(_ client: ITerm2APIClient, socketPath: String) async -> Int32 {
    let status = await client.status()
    let output = StatusOutput(
      running: status.isRunning,
      socketPath: socketPath,
      socketPresent: status.socketPresent,
      connected: status.isConnected,
      protocolVersion: status.protocolVersion,
      error: status.error.map(ErrorOutput.init))
    guard printJSON(output) else { return EX_SOFTWARE }
    guard let error = status.error else { return 0 }
    reportFailure(error)
    return exitStatus(for: error)
  } // End of func runStatus(_:socketPath:)

  /// The listing subcommands: prints the listing as JSON.
  static func runListing(_ action: Action, _ client: ITerm2APIClient) async -> Int32 {
    do {
      let printed: Bool
      switch action {
      case .listSessions:
        printed = printJSON(SessionsOutput(try await client.listSessions()))
      case .listConnections:
        printed = printJSON(ConnectionsOutput(try await client.listTmuxConnections()))
      case .listProfiles:
        let profiles = try await client.listProfiles(
          properties: [ITerm2API.ProfileProperty.Key.guid, ITerm2API.ProfileProperty.Key.name],
          guids: [])
        printed = printJSON(ProfilesOutput(profiles))
      case .status:
        printed = false
      }
      return printed ? 0 : EX_SOFTWARE
    } catch let error as ITerm2Error {
      reportFailure(error)
      return exitStatus(for: error)
    } catch {
      printError("muxfinder-probe: \(error)")
      return EX_SOFTWARE
    }
  } // End of func runListing(_:_:)

  /// Writes the one-line error for `error` to stderr.
  static func reportFailure(_ error: ITerm2Error) {
    let description = error.errorDescription ?? error.kind
    printError("muxfinder-probe: \(description) [\(error.kind)]")
  }

  /// The exit status for a failure, following `sysexits.h`; a request that was not sent exits
  /// with its reason's status.
  static func exitStatus(for error: ITerm2Error) -> Int32 {
    switch error {
    case .notSent(let reason): return exitStatus(for: reason)
    case .notRunning, .apiDisabled, .connectionFailed: return EX_UNAVAILABLE
    case .automationDenied, .authRejected, .cookieUnavailable: return EX_NOPERM
    case .protocolError: return EX_PROTOCOL
    case .timedOut, .disconnected: return EX_TEMPFAIL
    default: return EX_SOFTWARE
    }
  }

  /// Prints `value` as pretty-printed JSON with sorted keys. Returns whether it worked.
  static func printJSON(_ value: some Encodable) -> Bool {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else {
      printError("muxfinder-probe: could not encode the output")
      return false
    }
    print(String(decoding: data, as: UTF8.self))
    return true
  }

  /// `status` output.
  struct StatusOutput: Encodable {
    /// Whether iTerm2 runs.
    let running: Bool
    /// The socket path checked.
    let socketPath: String
    /// Whether the socket file exists.
    let socketPresent: Bool
    /// Whether an authenticated connection succeeded.
    let connected: Bool
    /// The handshake reply's `X-iTerm2-Protocol-Version`.
    let protocolVersion: String?
    /// Why the connection failed.
    let error: ErrorOutput?
  }

  /// A typed error as JSON.
  struct ErrorOutput: Encodable {
    /// `ITerm2Error.kind`.
    let kind: String
    /// The English explanation.
    let message: String

    /// Converts `error`.
    init(_ error: ITerm2Error) {
      kind = error.kind
      message = error.errorDescription ?? error.kind
    }
  }

  /// `list-sessions` output: ids and structure only, never titles.
  struct SessionsOutput: Encodable {
    /// Counts over every window.
    let summary: Summary
    /// The windows, in iTerm2's order.
    let windows: [WindowOutput]
    /// Ids of sessions that exist but are in no tab.
    let buriedSessionIDs: [String?]

    /// Counts.
    struct Summary: Encodable {
      /// Number of windows.
      let windows: Int
      /// Number of tabs.
      let tabs: Int
      /// Number of sessions in tabs (split panes and minimized ones).
      let sessions: Int
      /// Number of tabs of tmux integration connections (`ITerm2API.Tab.isTmuxTab`).
      let tmuxTabs: Int
      /// Number of buried sessions.
      let buriedSessions: Int
    }

    /// Converts a response.
    init(_ response: ITerm2API.ListSessionsResponse) {
      windows = response.windows.map(WindowOutput.init)
      buriedSessionIDs = response.buriedSessions.map(\.uniqueIdentifier)
      let tabs = response.windows.flatMap(\.tabs)
      summary = Summary(
        windows: response.windows.count,
        tabs: tabs.count,
        sessions: tabs.reduce(0) { $0 + $1.sessions.count },
        tmuxTabs: tabs.filter(\.isTmuxTab).count,
        buriedSessions: response.buriedSessions.count)
    } // End of init(_:) for a list-sessions response
  } // End of struct SessionsOutput

  /// One window.
  struct WindowOutput: Encodable {
    /// `window_id`.
    let windowID: String?
    /// The tabs, in order.
    let tabs: [TabOutput]

    /// Converts a window.
    init(_ window: ITerm2API.Window) {
      windowID = window.windowID
      tabs = window.tabs.map(TabOutput.init)
    }
  }

  /// One tab.
  struct TabOutput: Encodable {
    /// `tab_id`.
    let tabID: String?
    /// `tmux_window_id` as iTerm2 sends it (`"-1"` on ordinary tabs).
    let tmuxWindowID: String?
    /// `tmux_connection_id`, for tabs of a tmux integration connection.
    let tmuxConnectionID: String?
    /// Every session id in the tab: split tree first, then minimized sessions.
    let sessionIDs: [String?]
    /// The split tree.
    let layout: LayoutOutput?

    /// Converts a tab.
    init(_ tab: ITerm2API.Tab) {
      tabID = tab.tabID
      tmuxWindowID = tab.tmuxWindowID
      tmuxConnectionID = tab.tmuxConnectionID
      sessionIDs = tab.sessions.map(\.uniqueIdentifier)
      layout = tab.root.map(LayoutOutput.init)
    }
  }

  /// A split tree: `{"vertical": …, "children": […]}` for a splitter, `{"sessionID": …}` for a
  /// pane.
  indirect enum LayoutOutput: Encodable {
    /// A pane.
    case session(String?)
    /// A splitter and its children.
    case split(vertical: Bool, children: [LayoutOutput])

    /// Converts a split tree node.
    init(_ node: ITerm2API.SplitTreeNode) {
      self = .split(
        vertical: node.vertical,
        children: node.links.map { link in
          switch link {
          case .session(let session): return .session(session.uniqueIdentifier)
          case .node(let child): return LayoutOutput(child)
          }
        })
    }

    /// The JSON keys.
    enum CodingKeys: String, CodingKey {
      /// A pane's session id.
      case sessionID
      /// A splitter's orientation.
      case vertical
      /// A splitter's children.
      case children
    }

    /// Encodes the node.
    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      switch self {
      case .session(let id):
        try container.encode(id, forKey: .sessionID)
      case .split(let vertical, let children):
        try container.encode(vertical, forKey: .vertical)
        try container.encode(children, forKey: .children)
      }
    }
  } // End of enum LayoutOutput

  /// `list-connections` output.
  struct ConnectionsOutput: Encodable {
    /// Number of connections.
    let count: Int
    /// The connections.
    let connections: [Connection]

    /// One tmux integration connection.
    struct Connection: Encodable {
      /// `connection_id`.
      let connectionID: String?
      /// `owning_session_id`: the iTerm2 session running `tmux -CC`.
      let owningSessionID: String?
    }

    /// Converts the connections.
    init(_ connections: [ITerm2API.TmuxConnection]) {
      count = connections.count
      self.connections = connections.map {
        Connection(connectionID: $0.connectionID, owningSessionID: $0.owningSessionID)
      }
    }
  }

  /// `list-profiles` output.
  struct ProfilesOutput: Encodable {
    /// Number of profiles.
    let count: Int
    /// The profiles.
    let profiles: [Profile]

    /// One profile.
    struct Profile: Encodable {
      /// `"Guid"`.
      let guid: String?
      /// `"Name"`.
      let name: String?
    }

    /// Converts the profiles.
    init(_ profiles: [ITerm2API.Profile]) {
      count = profiles.count
      self.profiles = profiles.map { Profile(guid: $0.guid, name: $0.name) }
    }
  }
}
