import Foundation

/// Which tmux sessions are attached in this Mac's iTerm2 (PLAN.md Architecture and D16).
///
/// `snapshot(of:)` lists iTerm2's tmux integration connections and asks each one, through
/// `ITerm2Integration.sendTmuxCommand(_:connectionID:ownedBy:)` bound to the owning session
/// from that same listing (D15), which host, server and session it shows:
/// `ConnectionIdentity.command`, a read-only `display-message`. That is the only command the
/// index ever sends. Each answer is then matched against what discovery reported: the host's
/// `uname -n` must equal `#{host}`, and the host must have a server with the reported socket
/// path, pid and start time. Exactly one matching host maps the connection to
/// `SessionKey(hostID, server, session id)`; titles and names are never used.
///
/// A connection that matches no host is `unknown`, one that matches several is `ambiguous`, one
/// whose tmux client is not in UTF-8 mode and whose answer may have lost bytes is `nonUTF8`
/// (`ConnectionIdentity.Answer.nonUTF8`), and one that gives no usable answer (the request
/// failed, the answer is unreadable, or none came within `Configuration.commandTimeout`) is
/// `stale`. They stay unmapped and are counted, never guessed. The connections are asked concurrently and each request is bounded, so one
/// hung connection cannot stall the index.
public struct AttachmentIndex: Sendable {
  /// Options.
  public struct Configuration: Sendable {
    /// How long one connection may take to answer the identity command (a healthy local
    /// connection answers within tens of milliseconds).
    public static let defaultCommandTimeout: Duration = .seconds(3)

    /// How long one connection may take to answer the identity command.
    public var commandTimeout: Duration
    /// Which listed connections the index may ask; `nil` asks every one. Connections left out
    /// get no command and are only counted (`AttachmentSnapshot.Counts.excluded`). The real
    /// `e2e-local` run restricts the index to its own launch tabs' connections this way.
    public var includes: (@Sendable (ITerm2API.TmuxConnection) -> Bool)?

    /// Creates a configuration.
    public init(
      commandTimeout: Duration = Configuration.defaultCommandTimeout,
      includes: (@Sendable (ITerm2API.TmuxConnection) -> Bool)? = nil
    ) {
      self.commandTimeout = commandTimeout
      self.includes = includes
    }
  }

  /// One host as discovery last saw it: what a connection's answer is matched against.
  public struct Host: Sendable, Hashable {
    /// `HostConfig.id`, the host part of every key mapped to it.
    public var hostID: UUID
    /// The host's `uname -n` from its discovery report.
    public var nodeName: String
    /// The tmux servers discovery found on the host (the default server only, D9).
    public var servers: Set<ServerIdentity>

    /// Creates a host.
    public init(hostID: UUID, nodeName: String, servers: Set<ServerIdentity>) {
      self.hostID = hostID
      self.nodeName = nodeName
      self.servers = servers
    }

    /// The host as `result` reports it: its node name and the servers of its sessions (none
    /// when no server runs). `nil` when the result has no report or another status, since
    /// nothing can then be matched to the host.
    public init?(_ result: DiscoveryResult) {
      guard let report = result.report else { return nil }
      switch result.status {
      case .ok(let sessions):
        self.init(
          hostID: result.hostID, nodeName: report.nodeName,
          servers: Set(sessions.map(\.key.server)))
      case .noServer:
        self.init(hostID: result.hostID, nodeName: report.nodeName, servers: [])
      default:
        return nil
      }
    } // End of init?(_:)
  } // End of struct Host

  /// How one answer matches the hosts.
  public enum Mapping: Sendable, Hashable {
    /// Exactly one host has that node name and server.
    case mapped(SessionKey)
    /// No host has that node name and server.
    case unknown
    /// Several hosts have that node name and server (for example "This Mac" and an SSH entry
    /// for the same Mac); the number of them.
    case ambiguous(candidates: Int)
  }

  /// What one connection answered.
  public enum Identification: Sendable, Hashable {
    /// A readable, exact answer.
    case reported(ConnectionIdentity.Reported)
    /// An answer through a tmux client not in UTF-8 mode that may have lost bytes; never
    /// matched.
    case nonUTF8
    /// No usable answer.
    case stale(AttachmentSnapshot.StaleReason)
  }

  /// The iTerm2 backend.
  private let iTerm2: any ITerm2Integration
  /// The clock bounding each request.
  private let clock: any AttachClock
  /// Options.
  public let configuration: Configuration

  /// Creates an index. Tests pass fakes for iTerm2 and the clock.
  public init(
    iTerm2: any ITerm2Integration,
    clock: any AttachClock = SystemAttachClock(),
    configuration: Configuration = Configuration()
  ) {
    self.iTerm2 = iTerm2
    self.clock = clock
    self.configuration = configuration
  }

  /// Lists iTerm2's tmux connections, asks each included one which host, server and session
  /// it shows, and maps the answers against `hosts`.
  ///
  /// - Throws: the `ITerm2Error` of the connection listing (`notRunning` when iTerm2 does not
  ///   run: then nothing is attached in it), or `CancellationError` when the calling task is
  ///   cancelled. A connection's own failure never throws; it is counted as `stale`.
  public func snapshot(of hosts: [Host]) async throws -> AttachmentSnapshot {
    let listed = try await iTerm2.listTmuxConnections()
    let included = listed.filter { configuration.includes?($0) ?? true }
    let answers = await withTaskGroup(of: (Int, Identification).self) { group in
      for (offset, connection) in included.enumerated() {
        group.addTask {
          guard let connectionID = connection.connectionID, !connectionID.isEmpty,
            let owner = connection.owningSessionID, !owner.isEmpty
          else { return (offset, .stale(.incompleteListing)) }
          do {
            return (offset, try await identify(connectionID: connectionID, owningSessionID: owner))
          } catch {
            return (offset, .stale(.timedOut))
          }
        }
      } // End of loop over the included connections
      var answers = [Identification](repeating: .stale(.timedOut), count: included.count)
      for await (offset, answer) in group { answers[offset] = answer }
      return answers
    } // End of task group asking every included connection
    try Task.checkCancellation()
    var snapshot = AttachmentSnapshot(excludedCount: listed.count - included.count)
    for (connection, answer) in zip(included, answers) {
      switch answer {
      case .nonUTF8:
        snapshot.unmapped.append(
          .init(connection: connection, kind: .nonUTF8, staleReason: nil, reported: nil))
      case .stale(let reason):
        snapshot.unmapped.append(
          .init(connection: connection, kind: .stale, staleReason: reason, reported: nil))
      case .reported(let reported):
        switch Self.map(reported, among: hosts) {
        case .mapped(let key):
          snapshot.attachments.append(
            .init(
              key: key, connectionID: connection.connectionID ?? "",
              owningSessionID: connection.owningSessionID ?? ""))
        case .unknown:
          snapshot.unmapped.append(
            .init(connection: connection, kind: .unknown, staleReason: nil, reported: reported))
        case .ambiguous(let candidates):
          snapshot.unmapped.append(
            .init(
              connection: connection, kind: .ambiguous, staleReason: nil, reported: reported,
              candidateCount: candidates))
        }
      }
    } // End of loop over the answers
    return snapshot
  } // End of func snapshot(of:)

  /// Asks the connection `connectionID`, only while iTerm2 lists it as owned by
  /// `owningSessionID`, which host, server and session it shows (`ConnectionIdentity.command`,
  /// read with `ConnectionIdentity.read(_:)`), bounded by `Configuration.commandTimeout`. When the time is up the request is cancelled
  /// (iTerm2 drops its answer if it comes later) and the connection is `stale(.timedOut)`.
  ///
  /// - Throws: `CancellationError` only, when the calling task is cancelled before an outcome.
  public func identify(
    connectionID: String,
    owningSessionID: String
  ) async throws -> Identification {
    let iTerm2 = self.iTerm2
    let clock = self.clock
    let timeout = configuration.commandTimeout
    let outcome = await withTaskGroup(of: Identification?.self) { group -> Identification? in
      group.addTask {
        do {
          let output = try await iTerm2.sendTmuxCommand(
            ConnectionIdentity.command, connectionID: connectionID, ownedBy: owningSessionID)
          switch ConnectionIdentity.read(output) {
          case .reported(let reported): return .reported(reported)
          case .nonUTF8: return .nonUTF8
          case .unreadable: return .stale(.unreadable)
          }
        } catch let error as ITerm2Error {
          return .stale(.requestFailed(error))
        } catch {
          return nil
        }
      } // End of the command's child task
      group.addTask {
        do {
          try await clock.sleep(for: timeout)
        } catch {
          return nil
        }
        return .stale(.timedOut)
      }
      var first: Identification?
      while first == nil, let next = await group.next() { first = next }
      group.cancelAll()
      return first
    } // End of task group racing the command against its timeout
    guard let outcome else { throw CancellationError() }
    return outcome
  } // End of func identify(connectionID:owningSessionID:)

  /// Matches one answer against `hosts`: the hosts whose node name is the answer's `#{host}`
  /// and that have the answer's server. A host listed twice counts once.
  public static func map(_ reported: ConnectionIdentity.Reported, among hosts: [Host]) -> Mapping {
    let server = reported.server
    let candidates = Set(
      hosts.filter { $0.nodeName == reported.host && $0.servers.contains(server) }.map(\.hostID))
    switch candidates.count {
    case 0:
      return .unknown
    case 1:
      return .mapped(
        SessionKey(hostID: candidates.first!, server: server, sessionID: reported.sessionID))
    default:
      return .ambiguous(candidates: candidates.count)
    }
  } // End of func map(_:among:)
}

/// What `AttachmentIndex.snapshot(of:)` found: the mapped attachments and the unmapped
/// connections, by kind. Holds ids, servers and host names only, never titles or terminal
/// contents.
public struct AttachmentSnapshot: Sendable, Hashable {
  /// One connection mapped to a session.
  public struct Attachment: Sendable, Hashable {
    /// The session the connection shows.
    public var key: SessionKey
    /// The iTerm2 tmux connection.
    public var connectionID: String
    /// The iTerm2 session running its `tmux -CC` client (a launch tab, or a tab of the user's).
    public var owningSessionID: String

    /// Creates an attachment.
    public init(key: SessionKey, connectionID: String, owningSessionID: String) {
      self.key = key
      self.connectionID = connectionID
      self.owningSessionID = owningSessionID
    }
  }

  /// Why a connection stayed unmapped.
  public enum UnmappedKind: String, Sendable, Hashable, CaseIterable {
    /// Its answer matched no host's node name and server.
    case unknown
    /// Its answer matched several hosts.
    case ambiguous
    /// Its tmux client is not in UTF-8 mode (started without `-u` under a non-UTF-8 locale) and
    /// its answer may have lost bytes, so it cannot be matched exactly
    /// (`ConnectionIdentity.Answer.nonUTF8`).
    case nonUTF8
    /// It gave no usable answer.
    case stale
  }

  /// Why a connection gave no usable answer.
  public enum StaleReason: Sendable, Hashable {
    /// The listing gave it no connection id or no owning session, so no command could be bound
    /// to it.
    case incompleteListing
    /// The request failed: iTerm2's error (`tmuxConnectionNotOwned` when the connection closed
    /// or changed owner before the command, a `notSent` reason, a refusal, …).
    case requestFailed(ITerm2Error)
    /// No answer within the index's timeout.
    case timedOut
    /// The answer was not one line in `ConnectionIdentity.command`'s format (from a client in
    /// UTF-8 mode; a client that is not makes the connection `nonUTF8`).
    case unreadable

    /// A short machine-readable name, such as `timedOut`.
    public var kind: String {
      switch self {
      case .incompleteListing: return "incompleteListing"
      case .requestFailed: return "requestFailed"
      case .timedOut: return "timedOut"
      case .unreadable: return "unreadable"
      }
    }
  } // End of enum StaleReason

  /// One unmapped connection.
  public struct Unmapped: Sendable, Hashable {
    /// The connection id, as listed.
    public var connectionID: String?
    /// The owning session, as listed.
    public var owningSessionID: String?
    /// Why it is unmapped.
    public var kind: UnmappedKind
    /// For `stale`: why there is no usable answer.
    public var staleReason: StaleReason?
    /// For `unknown` and `ambiguous`: what the connection answered.
    public var reported: ConnectionIdentity.Reported?
    /// For `ambiguous`: how many hosts matched; otherwise 0.
    public var candidateCount: Int

    /// Creates an entry for a listed connection.
    public init(
      connection: ITerm2API.TmuxConnection,
      kind: UnmappedKind,
      staleReason: StaleReason?,
      reported: ConnectionIdentity.Reported?,
      candidateCount: Int = 0
    ) {
      connectionID = connection.connectionID
      owningSessionID = connection.owningSessionID
      self.kind = kind
      self.staleReason = staleReason
      self.reported = reported
      self.candidateCount = candidateCount
    } // End of init(connection:kind:staleReason:reported:candidateCount:)
  } // End of struct Unmapped

  /// How many connections ended up where.
  public struct Counts: Sendable, Hashable, Codable {
    /// Mapped to a session.
    public var mapped: Int
    /// Unmapped: no matching host.
    public var unknown: Int
    /// Unmapped: several matching hosts.
    public var ambiguous: Int
    /// Unmapped: a tmux client not in UTF-8 mode, whose answer may have lost bytes.
    public var nonUTF8: Int
    /// Unmapped: no usable answer.
    public var stale: Int
    /// Not asked (left out by `AttachmentIndex.Configuration.includes`).
    public var excluded: Int

    /// Creates counts.
    public init(
      mapped: Int = 0, unknown: Int = 0, ambiguous: Int = 0, nonUTF8: Int = 0, stale: Int = 0,
      excluded: Int = 0
    ) {
      self.mapped = mapped
      self.unknown = unknown
      self.ambiguous = ambiguous
      self.nonUTF8 = nonUTF8
      self.stale = stale
      self.excluded = excluded
    } // End of init(mapped:unknown:ambiguous:nonUTF8:stale:excluded:)

    /// Every unmapped connection.
    public var unmapped: Int { unknown + ambiguous + nonUTF8 + stale }
  } // End of struct Counts

  /// The mapped connections, in iTerm2's listing order.
  public var attachments: [Attachment]
  /// The unmapped connections, in iTerm2's listing order.
  public var unmapped: [Unmapped]
  /// How many listed connections were not asked.
  public var excludedCount: Int

  /// Creates a snapshot.
  public init(attachments: [Attachment] = [], unmapped: [Unmapped] = [], excludedCount: Int = 0) {
    self.attachments = attachments
    self.unmapped = unmapped
    self.excludedCount = excludedCount
  }

  /// The counts by kind.
  public var counts: Counts {
    Counts(
      mapped: attachments.count, unknown: unmapped.filter { $0.kind == .unknown }.count,
      ambiguous: unmapped.filter { $0.kind == .ambiguous }.count,
      nonUTF8: unmapped.filter { $0.kind == .nonUTF8 }.count,
      stale: unmapped.filter { $0.kind == .stale }.count, excluded: excludedCount)
  }

  /// The attachments of `key`, in listing order (more than one when several connections show
  /// the same session).
  public func attachments(of key: SessionKey) -> [Attachment] {
    attachments.filter { $0.key == key }
  }

  /// Every session that has at least one attachment.
  public var attachedKeys: Set<SessionKey> { Set(attachments.map(\.key)) }

  /// The unmapped connections that cannot be ruled out as showing `key` (PLAN.md D21), in
  /// listing order: every `stale` and `nonUTF8` one (no exact answer), and every `unknown` or
  /// `ambiguous` one whose exact answer names `key`'s server and session (only the host name
  /// failed to match). An exact answer naming another server or session rules its connection
  /// out, since `attach-session -d` detaches only clients of `key`'s session; so does a filter
  /// (`excludedCount`: never asked, on the word of the filter's owner). A move here runs only
  /// when this is empty; an attach ignores it.
  public func unresolvedConnections(for key: SessionKey) -> [Unmapped] {
    unmapped.filter { entry in
      switch entry.kind {
      case .stale, .nonUTF8: return true
      case .unknown, .ambiguous: return entry.reported?.matches(key) ?? true
      }
    }
  } // End of func unresolvedConnections(for:)
}
