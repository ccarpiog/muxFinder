import Foundation

/// A tmux session id such as `$3`: a `$` followed by decimal digits.
///
/// All tmux targets muxFinder builds use these ids, never names (PLAN.md D4). The value can only
/// be created through the validating initializer, so an id can never carry option syntax,
/// format syntax or shell metacharacters.
public struct TmuxSessionID: Sendable, Hashable, Codable, CustomStringConvertible {
  /// The most digits accepted after `$`. tmux numbers sessions from 0 upwards; this bound only
  /// keeps hostile input small.
  public static let maximumDigits = 18

  /// The id as tmux prints it, including the leading `$`.
  public let rawValue: String

  /// Validates `rawValue` against `^\$[0-9]+$` (at most `maximumDigits` digits). Returns `nil`
  /// for anything else.
  public init?(_ rawValue: String) {
    let bytes = Array(rawValue.utf8)
    guard Self.isValid(bytes[...]) else { return nil }
    self.rawValue = rawValue
  }

  /// Whether `bytes` is a `$` followed by 1 to `maximumDigits` ASCII digits.
  static func isValid(_ bytes: ArraySlice<UInt8>) -> Bool {
    guard bytes.first == UInt8(ascii: "$") else { return false }
    let digits = bytes.dropFirst()
    guard !digits.isEmpty, digits.count <= maximumDigits else { return false }
    return digits.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
  }

  /// The raw id, for example `$3`.
  public var description: String { rawValue }

  /// Decodes from a single string, validating it.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    guard let id = TmuxSessionID(raw) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Not a tmux session id."
      )
    }
    self = id
  } // End of init(from:)

  /// Encodes as a single string.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Identity of one running tmux server: where its socket is, and which process started when.
///
/// The pid alone is not enough because pids are reused; together with the server start time
/// it tells a restarted server (whose session ids start over) from the one seen before.
public struct ServerIdentity: Sendable, Hashable, Codable {
  /// The server's socket path, for example `/private/tmp/tmux-501/default` (`#{socket_path}`).
  public var socketPath: String
  /// The server's process id (`#{pid}`).
  public var pid: Int32
  /// When the server started, in seconds since 1970 (`#{start_time}`).
  public var startTime: Int64

  /// Creates a server identity.
  public init(socketPath: String, pid: Int32, startTime: Int64) {
    self.socketPath = socketPath
    self.pid = pid
    self.startTime = startTime
  }
}

/// The identity of one tmux session across refreshes (PLAN.md D4):
/// `(hostID, socketPath, serverPID, serverStartTime, sessionID)`.
///
/// The session name is deliberately not part of it; names are display data and can change.
public struct SessionKey: Sendable, Hashable, Codable {
  /// The configured host (`HostConfig.id`) the session was discovered on.
  public var hostID: UUID
  /// The tmux server the session lives in.
  public var server: ServerIdentity
  /// The session's id within that server.
  public var sessionID: TmuxSessionID

  /// Creates a session key.
  public init(hostID: UUID, server: ServerIdentity, sessionID: TmuxSessionID) {
    self.hostID = hostID
    self.server = server
    self.sessionID = sessionID
  }
}

/// One tmux client attached to a session, as `list-clients` reports it.
public struct ClientSummary: Sendable, Hashable, Codable {
  /// The client's process id (`#{client_pid}`).
  public var pid: Int32
  /// Whether the client is in control mode (`#{client_control_mode}`), as iTerm2's tmux
  /// integration uses. A control client does not by itself mean "open on this Mac".
  public var isControlMode: Bool

  /// Creates a client summary.
  public init(pid: Int32, isControlMode: Bool) {
    self.pid = pid
    self.isControlMode = isControlMode
  }
}

/// A tmux session found by discovery.
public struct DiscoveredSession: Sendable, Hashable, Codable, Identifiable {
  /// The session's identity.
  public var key: SessionKey
  /// The session name. Display text only: it never identifies a session and is never parsed or
  /// used as a target (`CreatedSession` compares it only as an extra check on a session its
  /// caller created).
  public var name: String
  /// When the session was created, in seconds since 1970 (`#{session_created}`). Kept for
  /// revalidation before attaching (PLAN.md D4).
  public var createdAt: Int64
  /// Number of windows (`#{session_windows}`).
  public var windowCount: Int
  /// Number of attached clients, as tmux counts them (`#{session_attached}`).
  public var attachedClientCount: Int
  /// Last activity, in seconds since 1970 (`#{session_activity}`).
  public var lastActivityAt: Int64
  /// The clients `list-clients` reported for this session.
  public var clients: [ClientSummary]

  /// Creates a discovered session.
  public init(
    key: SessionKey,
    name: String,
    createdAt: Int64,
    windowCount: Int,
    attachedClientCount: Int,
    lastActivityAt: Int64,
    clients: [ClientSummary]
  ) {
    self.key = key
    self.name = name
    self.createdAt = createdAt
    self.windowCount = windowCount
    self.attachedClientCount = attachedClientCount
    self.lastActivityAt = lastActivityAt
    self.clients = clients
  } // End of init(key:name:createdAt:windowCount:attachedClientCount:lastActivityAt:clients:)

  /// `Identifiable` conformance: the session key.
  public var id: SessionKey { key }
}
