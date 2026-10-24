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
/// Encoded as an object with a `kind` field (`{"kind":"local"}`,
/// `{"kind":"ssh","destination":"saturno-m4"}`), so a helper that does not know a kind refuses
/// the request as unreadable instead of guessing.
public enum LaunchHost: Sendable, Hashable, Codable {
  /// tmux on this Mac, run directly (never through ssh).
  case local
  /// tmux on a remote Mac, reached with `/usr/bin/ssh -t` from the launch tab (PLAN.md D17).
  /// The destination is a host name, `user@host` or an `~/.ssh/config` alias, valid per
  /// `Validation.sshDestination(_:)` (checked when the request is written and when it is taken).
  case ssh(destination: String)

  /// The `kind` values written to request files.
  private enum Kind: String, Codable {
    /// `LaunchHost.local`.
    case local
    /// `LaunchHost.ssh(destination:)`.
    case ssh
  }

  /// The JSON keys.
  private enum CodingKeys: String, CodingKey {
    /// The host kind.
    case kind
    /// The SSH destination of `ssh`.
    case destination
  }

  /// Decodes `{"kind": …}` plus the kind's fields; an unknown kind is a decoding error.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .local: self = .local
    case .ssh: self = .ssh(destination: try container.decode(String.self, forKey: .destination))
    }
  }

  /// Encodes `{"kind": …}` plus the kind's fields.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .local:
      try container.encode(Kind.local, forKey: .kind)
    case .ssh(let destination):
      try container.encode(Kind.ssh, forKey: .kind)
      try container.encode(destination, forKey: .destination)
    }
  }

  /// Whether tmux runs on another Mac, through ssh.
  public var isRemote: Bool {
    if case .ssh = self { return true }
    return false
  }
}

/// What a request file asks the helper to do: its `kind` field (PLAN.md D24). Each kind is
/// taken only by the helper mode of the same name (`helperMode`), so a request can never be
/// used for anything but what the app wrote it for.
///
/// An attach request carries no `kind` field at all: every request file written before ssh
/// setup existed, and every attach request written since, byte for byte, reads as an attach.
public enum LaunchRequestKind: String, Sendable, Hashable, Codable, CaseIterable {
  /// Attach a tmux session (`LaunchRequest`): `muxfinder-launch attach <launch id>`.
  case attach
  /// Run plain interactive ssh to a destination (`SSHSetupRequest`): `muxfinder-launch
  /// ssh-setup <launch id>`, the "Set up SSH in iTerm2…" action.
  case sshSetup

  /// The helper's first argument for this kind.
  public var helperMode: String {
    switch self {
    case .attach: return "attach"
    case .sshSetup: return "ssh-setup"
    }
  }
}

/// What the app asks the helper to attach, written to a 0600 request file (PLAN.md D2).
///
/// It holds ids, numbers, at most one path (the tmux override) and, for a remote host, the SSH
/// destination; never a session name or terminal content. The D4 expectations
/// (`expectedServerPID`, `expectedServerStartTime`, `expectedSessionCreated`) are what the
/// guard compares with tmux before attaching, locally or on the remote host (PLAN.md D17).
/// Its file has no `kind` field (`LaunchRequestKind.attach`, PLAN.md D24).
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
  /// Test mode only (PLAN.md D14 *Test mode*): how many seconds the helper waits before its
  /// first child, with nothing running, so its launch tab stays open with no tmux connection
  /// and no result (`e2e-remote`'s `still waiting` step). A helper not in test mode ignores
  /// it. Absent (`nil`, not written to the file) in every request the app writes; when set it
  /// must be within `testLaunchDelayRange`.
  public var testLaunchDelaySeconds: Int? = nil
  /// Test mode only (PLAN.md Phase 13a, spike (b)): `true` makes the helper write no
  /// `Disinter` sequence when its attach child has ended (it still writes the status report
  /// requests and waits for their answers), so a launch tab buried through the API stays
  /// buried. A helper not in test mode ignores it, so a request alone can never suppress the
  /// restore. Absent (`nil`, not written to the file) in every request the app writes.
  public var testSuppressDisinter: Bool? = nil
  /// Move here (PLAN.md D21): whether tmux detaches the session's other clients as it attaches
  /// (`attach-session -d`). Absent (`nil`, not written to the file) in every request of a
  /// normal attach, so a request without the field, including one written before Move here
  /// existed, attaches normally; `false` means the same. Only
  /// `AttachCoordinator.moveHere(_:confirmation:)` writes `true`.
  public var detachOtherClients: Bool? = nil

  /// The values `testLaunchDelaySeconds` may take.
  public static let testLaunchDelayRange = 1...120

  /// Whether the attach detaches the session's other clients (`detachOtherClients` is `true`).
  public var detachesOtherClients: Bool { detachOtherClients == true }

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
  /// times, a test launch delay (if any) within `testLaunchDelayRange`, a valid override path
  /// (absolute, no control characters) and, for an SSH host, a valid destination (not empty,
  /// no whitespace or control characters, no leading `-`).
  public var isWellFormed: Bool {
    guard formatVersion == Self.currentFormatVersion, expectedServerPID > 0,
      expectedServerStartTime >= 0, expectedSessionCreated >= 0
    else { return false }
    if let delay = testLaunchDelaySeconds, !Self.testLaunchDelayRange.contains(delay) {
      return false
    }
    if case .ssh(let destination) = host,
      (try? Validation.sshDestination(destination)) == nil
    {
      return false
    }
    if let override = tmuxPathOverride {
      return (try? Validation.executablePath(override)) != nil
    }
    return true
  } // End of var isWellFormed
}

/// What the app asks the helper to run for "Set up SSH in iTerm2…" (PLAN.md D24): plain
/// interactive `/usr/bin/ssh -- <destination>` in a launch tab, so the user can answer a
/// host-key question or sign in the way they always do. Written to a 0600 request file like an
/// attach request, with `"kind":"sshSetup"`, and taken only by `muxfinder-launch ssh-setup`.
///
/// It holds the launch id, the time, the configured host's id (for diagnostics) and the SSH
/// destination; nothing else, never terminal content. The destination must pass
/// `Validation.sshDestination(_:)` (not empty, no whitespace or control characters, no leading
/// `-`), checked before the request is written, when it is taken, and again before ssh starts.
public struct SSHSetupRequest: Sendable, Hashable, Codable {
  /// The format version this build writes and accepts.
  public static let currentFormatVersion = 1

  /// The file format version.
  public var formatVersion: Int
  /// Always `LaunchRequestKind.sshSetup`; written to the file so no other helper mode takes it.
  public var kind: LaunchRequestKind
  /// The launch id, also the file name and the helper's argument.
  public var id: LaunchToken
  /// When the request was written; it expires `LaunchStore.timeToLive` later.
  public var createdAt: Date
  /// The configured host (`HostConfig.id`), for diagnostics.
  public var hostID: UUID
  /// The SSH destination: a host name, `user@host` or an `~/.ssh/config` alias.
  public var destination: String

  /// Creates a request.
  public init(
    id: LaunchToken = LaunchToken(),
    createdAt: Date,
    hostID: UUID,
    destination: String
  ) {
    formatVersion = Self.currentFormatVersion
    kind = .sshSetup
    self.id = id
    self.createdAt = createdAt
    self.hostID = hostID
    self.destination = destination
  } // End of init(id:createdAt:hostID:destination:)

  /// Whether every field is usable: the current format version, the `sshSetup` kind and a
  /// destination that passes `Validation.sshDestination(_:)`.
  public var isWellFormed: Bool {
    formatVersion == Self.currentFormatVersion && kind == .sshSetup
      && (try? Validation.sshDestination(destination)) != nil
  }
}

/// One request file as the store reads it (PLAN.md D24): its `kind` field decides how the rest
/// is read. No `kind` (every attach request, including those written before ssh setup existed)
/// or `"attach"` is a `LaunchRequest`; `"sshSetup"` is an `SSHSetupRequest`; any other value
/// makes the file unreadable.
public enum LaunchRequestFile: Sendable, Hashable {
  /// An attach request.
  case attach(LaunchRequest)
  /// An ssh setup request.
  case sshSetup(SSHSetupRequest)

  /// Reads only the `kind` field.
  private struct KindField: Decodable {
    /// The kind, if the file names one.
    var kind: LaunchRequestKind?
  }

  /// Decodes a request file's JSON by its kind. Throws a `DecodingError` for an unknown kind
  /// or a body that does not fit it.
  static func decode(_ data: Data) throws -> LaunchRequestFile {
    let decoder = LaunchCoding.decoder()
    switch try decoder.decode(KindField.self, from: data).kind ?? .attach {
    case .attach: return .attach(try decoder.decode(LaunchRequest.self, from: data))
    case .sshSetup: return .sshSetup(try decoder.decode(SSHSetupRequest.self, from: data))
    }
  }

  /// The request's kind.
  public var kind: LaunchRequestKind {
    switch self {
    case .attach: return .attach
    case .sshSetup: return .sshSetup
    }
  }

  /// The request's launch id.
  public var id: LaunchToken {
    switch self {
    case .attach(let request): return request.id
    case .sshSetup(let request): return request.id
    }
  }

  /// When the request was written.
  public var createdAt: Date {
    switch self {
    case .attach(let request): return request.createdAt
    case .sshSetup(let request): return request.createdAt
    }
  }

  /// Whether the request's fields are usable (its own `isWellFormed`).
  public var isWellFormed: Bool {
    switch self {
    case .attach(let request): return request.isWellFormed
    case .sshSetup(let request): return request.isWellFormed
    }
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
