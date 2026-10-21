import Foundation

/// The id of one launch: a UUID written in canonical lowercase form, the only data iTerm2 ever
/// receives besides the helper's path (PLAN.md D2).
///
/// The string form is validated strictly (`8-4-4-4-12` lowercase hexadecimal digits, nothing
/// else) before it is used in a file name, so a token can never carry `/`, `..` or any other
/// path syntax.
public struct LaunchToken: Sendable, Hashable, Codable, CustomStringConvertible {
  /// The UUID.
  public let uuid: UUID

  /// Wraps `uuid`. The default is a fresh random UUID.
  public init(uuid: UUID = UUID()) {
    self.uuid = uuid
  }

  /// Parses the canonical lowercase form, for example
  /// `0f8fad5b-d9cb-469f-a165-70867728950e`. Returns `nil` for anything else, including the
  /// uppercase form `UUID.uuidString` produces.
  public init?(_ string: String) {
    let bytes = Array(string.utf8)
    guard bytes.count == 36 else { return nil }
    for (index, byte) in bytes.enumerated() {
      if [8, 13, 18, 23].contains(index) {
        guard byte == UInt8(ascii: "-") else { return nil }
      } else {
        let isDigit = byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        let isLowerHex = byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f")
        guard isDigit || isLowerHex else { return nil }
      }
    } // End of loop over the token's bytes
    guard let uuid = UUID(uuidString: string) else { return nil }
    self.uuid = uuid
  } // End of init?(_:)

  /// The canonical lowercase form, as used in file names and on the helper's command line.
  public var rawValue: String { uuid.uuidString.lowercased() }

  /// Same as `rawValue`.
  public var description: String { rawValue }

  /// Decodes from the canonical lowercase string, validating it.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    guard let token = LaunchToken(raw) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a launch id.")
    }
    self = token
  }

  /// Encodes as the canonical lowercase string.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Where the helper runs tmux.
///
/// Encoded as an object with a `kind` field (`{"kind":"local"}`), so the ssh kind Phase 5 adds
/// becomes one more case with its own fields, and a helper that does not know a kind refuses
/// the request as unreadable instead of guessing.
public enum LaunchHost: Sendable, Hashable, Codable {
  /// tmux on this Mac, run directly (never through ssh).
  case local

  /// The `kind` values written to request files.
  private enum Kind: String, Codable {
    /// `LaunchHost.local`.
    case local
  }

  /// The JSON keys.
  private enum CodingKeys: String, CodingKey {
    /// The host kind.
    case kind
  }

  /// Decodes `{"kind": …}`; an unknown kind is a decoding error.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .local: self = .local
    }
  }

  /// Encodes `{"kind": …}`.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .local: try container.encode(Kind.local, forKey: .kind)
    }
  }
}

/// What the app asks the helper to attach, written to a 0600 request file (PLAN.md D2).
///
/// It holds ids, numbers and at most one path (the tmux override), never a session name or
/// terminal content. The D4 expectations (`expectedServerPID`, `expectedServerStartTime`,
/// `expectedSessionCreated`) are what the guard compares with tmux before attaching.
public struct LaunchRequest: Sendable, Hashable, Codable {
  /// The format version this build writes and accepts.
  public static let currentFormatVersion = 1

  /// The file format version.
  public var formatVersion: Int
  /// The launch id, also the file name and the helper's argument.
  public var id: LaunchToken
  /// When the request was written; it expires `LaunchStore.timeToLive` later.
  public var createdAt: Date
  /// Where tmux runs.
  public var host: LaunchHost
  /// The configured host (`HostConfig.id`), for diagnostics.
  public var hostID: UUID
  /// The host's explicit tmux path, used alone when set (PLAN.md D5).
  public var tmuxPathOverride: String?
  /// The session to attach, as a `$N` id.
  public var sessionID: TmuxSessionID
  /// The tmux server's pid seen by discovery (`#{pid}`).
  public var expectedServerPID: Int32
  /// The tmux server's start time seen by discovery (`#{start_time}`).
  public var expectedServerStartTime: Int64
  /// The session's creation time seen by discovery (`#{session_created}`).
  public var expectedSessionCreated: Int64

  /// Creates a request from explicit values.
  public init(
    id: LaunchToken = LaunchToken(),
    createdAt: Date,
    host: LaunchHost,
    hostID: UUID,
    tmuxPathOverride: String?,
    sessionID: TmuxSessionID,
    expectedServerPID: Int32,
    expectedServerStartTime: Int64,
    expectedSessionCreated: Int64
  ) {
    formatVersion = Self.currentFormatVersion
    self.id = id
    self.createdAt = createdAt
    self.host = host
    self.hostID = hostID
    self.tmuxPathOverride = tmuxPathOverride
    self.sessionID = sessionID
    self.expectedServerPID = expectedServerPID
    self.expectedServerStartTime = expectedServerStartTime
    self.expectedSessionCreated = expectedSessionCreated
  } // End of init(id:createdAt:host:hostID:tmuxPathOverride:sessionID:…)

  /// Creates a request for a session discovery just reported, with its identity as the
  /// expectations.
  public init(
    id: LaunchToken = LaunchToken(),
    createdAt: Date,
    host: LaunchHost,
    tmuxPathOverride: String?,
    session: DiscoveredSession
  ) {
    self.init(
      id: id,
      createdAt: createdAt,
      host: host,
      hostID: session.key.hostID,
      tmuxPathOverride: tmuxPathOverride,
      sessionID: session.key.sessionID,
      expectedServerPID: session.key.server.pid,
      expectedServerStartTime: session.key.server.startTime,
      expectedSessionCreated: session.createdAt
    )
  } // End of init(id:createdAt:host:tmuxPathOverride:session:)

  /// Whether every field is usable: the current format version, positive pid, non-negative
  /// times and a valid override path (absolute, no control characters).
  public var isWellFormed: Bool {
    guard formatVersion == Self.currentFormatVersion, expectedServerPID > 0,
      expectedServerStartTime >= 0, expectedSessionCreated >= 0
    else { return false }
    if let override = tmuxPathOverride {
      return (try? Validation.executablePath(override)) != nil
    }
    return true
  }
}

/// What the helper reports when its child has ended (or could not start), written to a 0600
/// result file next to the request. Holds no terminal content.
public struct LaunchResult: Sendable, Equatable, Codable {
  /// The format version this build writes.
  public static let currentFormatVersion = 1

  /// The file format version.
  public var formatVersion: Int
  /// The launch id of the request this result answers.
  public var id: LaunchToken
  /// The helper's process id.
  public var helperPID: Int32
  /// When the helper started.
  public var startedAt: Date
  /// When the child (the guard, then tmux) started, if it did.
  public var childStartedAt: Date?
  /// When the helper finished.
  public var endedAt: Date
  /// How the child ended, if it ran.
  public var childTermination: ProcessResult.Termination?
  /// Why the launch failed, or `nil` when the child exited with status 0 (tmux detached).
  public var failure: LaunchFailure?
  /// The helper's own exit status (`LaunchFailure.exitStatus`, or 0).
  public var exitStatus: Int32

  /// Creates a result.
  public init(
    id: LaunchToken,
    helperPID: Int32,
    startedAt: Date,
    childStartedAt: Date?,
    endedAt: Date,
    childTermination: ProcessResult.Termination?,
    failure: LaunchFailure?
  ) {
    formatVersion = Self.currentFormatVersion
    self.id = id
    self.helperPID = helperPID
    self.startedAt = startedAt
    self.childStartedAt = childStartedAt
    self.endedAt = endedAt
    self.childTermination = childTermination
    self.failure = failure
    exitStatus = failure?.exitStatus ?? LaunchExitStatus.success
  } // End of init(id:helperPID:startedAt:childStartedAt:endedAt:childTermination:failure:)

  /// Whether the launch succeeded.
  public var succeeded: Bool { failure == nil }
}

/// `{"kind":"exited","status":N}` or `{"kind":"signaled","signal":N}`, as stored in result
/// files.
extension ProcessResult.Termination: Codable {
  /// The JSON keys.
  private enum CodingKeys: String, CodingKey {
    /// `exited` or `signaled`.
    case kind
    /// The exit status.
    case status
    /// The signal number.
    case signal
  }

  /// Decodes the object form.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .kind)
    switch kind {
    case "exited":
      self = .exited(try container.decode(Int32.self, forKey: .status))
    case "signaled":
      self = .signaled(try container.decode(Int32.self, forKey: .signal))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind,
        in: container,
        debugDescription: "Unknown termination kind."
      )
    }
  } // End of init(from:)

  /// Encodes the object form.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .exited(let status):
      try container.encode("exited", forKey: .kind)
      try container.encode(status, forKey: .status)
    case .signaled(let signal):
      try container.encode("signaled", forKey: .kind)
      try container.encode(signal, forKey: .signal)
    }
  } // End of func encode(to:)
}

/// The JSON encoding of launch files: sorted keys and ISO 8601 dates with milliseconds, so files
/// are stable and readable when debugging.
enum LaunchCoding {
  /// The date format.
  static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  /// A configured encoder.
  static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(date.formatted(dateStyle))
    }
    return encoder
  }

  /// A configured decoder.
  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let text = try container.decode(String.self)
      guard let date = try? dateStyle.parse(text) else {
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a date.")
      }
      return date
    }
    return decoder
  } // End of func decoder()
}
