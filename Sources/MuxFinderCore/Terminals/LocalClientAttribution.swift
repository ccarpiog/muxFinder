import Darwin
import Foundation

/// A terminal app a tmux client on This Mac runs in, as its process ancestry names it (PLAN.md
/// D38, Phase I-12c2; requirement 7 of `autoclaude/processed/110-other-terminal-apps.md`):
/// iTerm2, or the app of one or more loaded terminal definitions.
public struct LocalTerminalApp: Sendable, Hashable {
  /// iTerm2's bundle identifier.
  public static let iTerm2BundleIdentifier = "com.googlecode.iterm2"

  /// The app's bundle identifier, as its process reported it (iTerm2's constant for a client
  /// under iTerm2's job server).
  public let bundleIdentifier: String
  /// The ids of the loaded definitions whose bundle identifier is the app's, in loader order
  /// (sorted by id); none for iTerm2 unless a user definition names its bundle identifier.
  public let definitionIDs: [String]

  /// The app `bundleIdentifier` with `definitionIDs`; `nil` when it is neither iTerm2 nor any
  /// definition's app, which ancestry never names.
  public init?(bundleIdentifier: String, definitionIDs: [String]) {
    guard Self.isITerm2(bundleIdentifier) || !definitionIDs.isEmpty else { return nil }
    self.bundleIdentifier = bundleIdentifier
    self.definitionIDs = definitionIDs
  }

  /// iTerm2, with the definitions that name its bundle identifier (normally none).
  public static func iTerm2(definitionIDs: [String] = []) -> LocalTerminalApp {
    LocalTerminalApp(bundleIdentifier: iTerm2BundleIdentifier, definitionIDs: definitionIDs)!
  }

  /// Whether the app is iTerm2.
  public var isITerm2: Bool { Self.isITerm2(bundleIdentifier) }

  /// The terminal the app is in muxFinder's terms: `iterm2`, else the first definition's plain
  /// terminal (an app other than iTerm2 always has one: `init?` refuses it without).
  public var terminal: LaunchTerminalApp {
    if isITerm2 { return .iterm2 }
    return .plain(definitionID: definitionIDs.first ?? "")
  }

  /// Whether `bundleIdentifier` is iTerm2's (bundle identifiers compare without case, as
  /// LaunchServices compares them).
  static func isITerm2(_ bundleIdentifier: String) -> Bool {
    LocalClientAttributor.sameBundle(bundleIdentifier, iTerm2BundleIdentifier)
  }
} // End of struct LocalTerminalApp

/// Why a tmux client on This Mac was not traced to a terminal app. Never guessed: an unmapped
/// client never blocks an attach and counts as no app (PLAN.md D16's unmapped kinds, D38).
public enum LocalClientUnmappedReason: String, Sendable, Hashable, CaseIterable {
  /// Discovery gave no usable terminal path or creation time for the client (a client with no
  /// terminal, or an older probe), so its process cannot be checked to be the client.
  case incompleteClient
  /// The client's process, or one of its ancestors, ended (or its pid was reused) during the
  /// walk.
  case processGone
  /// The process table could not be read.
  case unreadable
  /// The client's process has another controlling terminal than the client's path (or none):
  /// the pid now names another process.
  case terminalMismatch
  /// The client's process started more than a second after tmux created the client: the pid
  /// now names another process.
  case startedAfterClient
  /// The walk reached launchd, the kernel or a pid it had seen with no terminal app on the
  /// way: a client over ssh, inside another tmux session, or in an app with no definition.
  case noTerminalAncestor
  /// No terminal app within `LocalClientAttributor.maximumSteps` parents.
  case tooDeep
}

/// What process ancestry says about one tmux client on This Mac.
public enum LocalClientAttribution: Sendable, Hashable {
  /// The client descends from this terminal app.
  case app(LocalTerminalApp)
  /// It was not traced to one.
  case unmapped(LocalClientUnmappedReason)

  /// The app, when attributed.
  public var app: LocalTerminalApp? {
    if case .app(let app) = self { return app }
    return nil
  }
}

/// One tmux client of a session on This Mac traced to a terminal app: "open in <app> on this
/// Mac" (PLAN.md D38, Phase I-12c2).
public struct LocalAttachment: Sendable, Hashable {
  /// The terminal app.
  public let app: LocalTerminalApp
  /// The client's process id (`#{client_pid}`).
  public let clientPID: Int32
  /// The client's terminal (`#{client_tty}`).
  public let terminalPath: String
  /// Whether the client is in control mode (`#{client_control_mode}`).
  public let isControlMode: Bool

  /// An attachment of these values.
  public init(app: LocalTerminalApp, clientPID: Int32, terminalPath: String, isControlMode: Bool) {
    self.app = app
    self.clientPID = clientPID
    self.terminalPath = terminalPath
    self.isControlMode = isControlMode
  }

  /// The per-session rule (PLAN.md D38, Phase I-12c2): one attachment per attributed client,
  /// in the session's client order. With D16's index in use (iTerm2 chosen), a control-mode
  /// client attributed to iTerm2 is left to the index, so D16's mapping and its unmapped kinds
  /// stay as they are; without it (iTerm2 not chosen, so never contacted) every attributed
  /// client counts, iTerm2's control-mode clients included.
  public static func counted(
    _ attributed: [(client: ClientSummary, attribution: LocalClientAttribution)],
    indexInUse: Bool
  ) -> [LocalAttachment] {
    attributed.compactMap { client, attribution in
      guard let app = attribution.app, let path = client.terminalPath else { return nil }
      if indexInUse, client.isControlMode, app.isITerm2 { return nil }
      return LocalAttachment(
        app: app, clientPID: client.pid, terminalPath: path, isControlMode: client.isControlMode)
    }
  } // End of static func counted(_:indexInUse:)
} // End of struct LocalAttachment

/// Traces This Mac's sessions' clients to terminal apps, for the refresh engine and the plain
/// backend. `LocalClientAttributor` is the production implementation; tests use it over a
/// `FakeProcessTable`.
public protocol LocalClientAttributing: Sendable {
  /// The local attachments of every session in `sessions` discovered on `host`, by session
  /// (`LocalAttachment.counted(_:indexInUse:)`); empty for an SSH host, whose clients run on
  /// that host and are never attributed.
  func localAttachments(
    of sessions: [DiscoveredSession],
    on host: HostConfig,
    indexInUse: Bool
  ) -> [SessionKey: [LocalAttachment]]
}

/// Process ancestry, read-only (PLAN.md D38, Phase I-12c2; requirement 7): which terminal app a
/// tmux client on This Mac runs in.
///
/// - **The client first, pid reuse refused.** The client's process must have the controlling
///   terminal whose device is the client's terminal path's (`stat`'s `st_rdev`), and must not
///   have started more than one second after tmux created the client (`#{client_created}` is
///   in whole seconds); a client with no usable terminal path or creation time is unmapped
///   (`incompleteClient`).
/// - **The walk** goes from the client's process up its parents, at most `maximumSteps` (64)
///   steps, and stops at pid 1 or 0 or a pid it has seen (`noTerminalAncestor`). The first
///   process whose bundle identifier is iTerm2's or that of any loaded definition names the
///   app; a process that is iTerm2's job server (an executable named `iTermServer-*` directly
///   in `~/Library/Application Support/iTerm2/` of the user's real home) names iTerm2 whatever
///   its parent, since iTerm2 runs every session's processes under it and its parent is
///   launchd once iTerm2 restarted. A parent that started after its child is another process
///   with a reused pid (`processGone`).
/// - **Only This Mac.** An SSH host's clients are never attributed: their processes run on that
///   host. A remote session attached by hand in a plain terminal is "attached somewhere",
///   unless the plain backend's own record or D16's index says otherwise.
///
/// It reads the table through `ProcessTableReading` only: nothing is signalled, launched or
/// sent an Apple event.
public struct LocalClientAttributor: LocalClientAttributing {
  /// The most parents the walk visits.
  public static let maximumSteps = 64
  /// The prefix of the name of iTerm2's job server executable (`iTermServer-3.7.7`).
  public static let iTerm2JobServerPrefix = "iTermServer-"

  /// The process table.
  public let table: any ProcessTableReading
  /// The loaded definitions, in loader order (`TerminalDefinitionCatalog.definitions`).
  public let definitions: [LoadedTerminalDefinition]
  /// The folder iTerm2's job servers run from (`~/Library/Application Support/iTerm2` of the
  /// user's real home); `nil` recognizes none.
  public let iTerm2JobServerDirectory: String?

  /// An attributor over `table` for the loaded `definitions`, recognizing iTerm2's job servers
  /// in `iTerm2JobServerDirectory` (by default the real home's; tests pass their own).
  public init(
    table: any ProcessTableReading = SystemProcessTable(),
    definitions: [LoadedTerminalDefinition],
    iTerm2JobServerDirectory: String? = LocalClientAttributor.realITerm2JobServerDirectory()
  ) {
    self.table = table
    self.definitions = definitions
    self.iTerm2JobServerDirectory = iTerm2JobServerDirectory.map(Self.withoutTrailingSlash)
  }

  /// See `LocalClientAttributing`: This Mac's sessions only, each client attributed once.
  public func localAttachments(
    of sessions: [DiscoveredSession],
    on host: HostConfig,
    indexInUse: Bool
  ) -> [SessionKey: [LocalAttachment]] {
    guard host.mode == .local else { return [:] }
    var result: [SessionKey: [LocalAttachment]] = [:]
    for session in sessions where session.key.hostID == host.id {
      let attributed = session.clients.map { (client: $0, attribution: attribute($0)) }
      let found = LocalAttachment.counted(attributed, indexInUse: indexInUse)
      if !found.isEmpty { result[session.key] = found }
    } // End of loop over the sessions
    return result
  } // End of func localAttachments(of:on:indexInUse:)

  /// The terminal app `client` (a client of a session on This Mac) descends from, or why it
  /// was not traced to one.
  public func attribute(_ client: ClientSummary) -> LocalClientAttribution {
    guard let path = client.terminalPath, let created = client.createdAt else {
      return .unmapped(.incompleteClient)
    }
    var current: ProcessTableEntry
    switch table.process(client.pid) {
    case .gone: return .unmapped(.processGone)
    case .unreadable: return .unmapped(.unreadable)
    case .found(let entry): current = entry
    }
    guard let device = table.terminalDevice(atPath: path), current.controllingTerminal == device
    else { return .unmapped(.terminalMismatch) }
    guard !Self.started(current.startTime, after: created) else {
      return .unmapped(.startedAfterClient)
    }
    var seen: Set<Int32> = [current.pid]
    var steps = 0
    while true {
      if let app = app(of: current) { return .app(app) }
      let parent = current.parentPID
      guard parent > 1, seen.insert(parent).inserted else {
        return .unmapped(.noTerminalAncestor)
      }
      guard steps < Self.maximumSteps else { return .unmapped(.tooDeep) }
      steps += 1
      switch table.process(parent) {
      case .gone: return .unmapped(.processGone)
      case .unreadable: return .unmapped(.unreadable)
      case .found(let entry):
        // A parent never starts after its child: one that did is another process.
        guard !Self.isLater(entry.startTime, than: current.startTime) else {
          return .unmapped(.processGone)
        }
        current = entry
      }
    } // End of loop up the client's parents
  } // End of func attribute(_:)

  /// The app `entry` is, if it names one: iTerm2 or a definition's app by bundle identifier,
  /// or iTerm2 for its job server.
  func app(of entry: ProcessTableEntry) -> LocalTerminalApp? {
    if let identifier = entry.bundleIdentifier {
      let isITerm2 = LocalTerminalApp.isITerm2(identifier)
      let bundle = isITerm2 ? LocalTerminalApp.iTerm2BundleIdentifier : identifier
      if let app = LocalTerminalApp(
        bundleIdentifier: bundle, definitionIDs: definitionIDs(sharing: bundle))
      {
        return app
      }
    }
    if let path = entry.executablePath, isITerm2JobServer(path) {
      return .iTerm2(definitionIDs: definitionIDs(sharing: LocalTerminalApp.iTerm2BundleIdentifier))
    }
    return nil
  } // End of func app(of:)

  /// The ids of the loaded definitions whose bundle identifier is `bundleIdentifier`, in
  /// loader order.
  func definitionIDs(sharing bundleIdentifier: String) -> [String] {
    definitions.filter { Self.sameBundle($0.definition.bundleIdentifier, bundleIdentifier) }
      .map(\.definition.id)
  }

  /// Whether `path` is an executable named `iTermServer-*` directly in the job server folder.
  func isITerm2JobServer(_ path: String) -> Bool {
    guard let directory = iTerm2JobServerDirectory, path.hasPrefix(directory + "/") else {
      return false
    }
    let name = path.dropFirst(directory.count + 1)
    return name.hasPrefix(Self.iTerm2JobServerPrefix) && !name.contains("/")
  }

  /// Whether a process that started at `start` started more than one second after `created`
  /// (whole seconds, so up to a second of rounding is allowed).
  static func started(_ start: ProcessStartTime, after created: Int64) -> Bool {
    let (limit, overflow) = created.addingReportingOverflow(1)
    if overflow { return false }
    return start.seconds > limit || (start.seconds == limit && start.microseconds > 0)
  }

  /// Whether `start` is later than `other`.
  static func isLater(_ start: ProcessStartTime, than other: ProcessStartTime) -> Bool {
    (start.seconds, start.microseconds) > (other.seconds, other.microseconds)
  }

  /// Whether two bundle identifiers are the same, compared without ASCII case.
  static func sameBundle(_ left: String, _ right: String) -> Bool {
    left.lowercased() == right.lowercased()
  }

  /// `path` without trailing slashes (`/` stays).
  static func withoutTrailingSlash(_ path: String) -> String {
    var text = Substring(path)
    while text.count > 1, text.hasSuffix("/") { text = text.dropLast() }
    return String(text)
  }

  /// `~/Library/Application Support/iTerm2` of the user's real home (`getpwuid_r` for the real
  /// uid, so neither `HOME` nor `CFFIXED_USER_HOME` moves it); `nil` when it cannot be read.
  public static func realITerm2JobServerDirectory() -> String? {
    var entry = passwd()
    var result: UnsafeMutablePointer<passwd>?
    var buffer = [CChar](repeating: 0, count: 16 * 1024)
    guard getpwuid_r(getuid(), &entry, &buffer, buffer.count, &result) == 0, result != nil,
      let home = entry.pw_dir
    else { return nil }
    let text = withoutTrailingSlash(String(cString: home))
    guard text.hasPrefix("/") else { return nil }
    return (text == "/" ? "" : text) + "/Library/Application Support/iTerm2"
  } // End of static func realITerm2JobServerDirectory()
} // End of struct LocalClientAttributor
