import Foundation

/// Why the persistent profile document could not be made. `message` is English, sentence case.
public enum PersistentProfileError: Error, Sendable, Hashable, LocalizedError {
  /// The helper's path cannot be given to iTerm2 safely (PLAN.md D2): it is not absolute or
  /// holds a character outside `[A-Za-z0-9._/-]`, so the profile's `Command` could not be split
  /// into exactly `<helper> profile <host id>`.
  case unsupportedHelperPath(LaunchHelperPathError)
  /// The document could not be encoded.
  case encodingFailed
  /// The document is larger than `PersistentProfiles.maximumFileSize`.
  case documentTooLarge

  /// The user-facing explanation.
  public var message: String {
    switch self {
    case .unsupportedHelperPath(let error):
      return error.message
    case .encodingFailed:
      return "muxFinder couldn't write its persistent work profiles."
    case .documentTooLarge:
      return "muxFinder's persistent work profiles are too large to write."
    }
  } // End of var message

  /// `LocalizedError` conformance, so `localizedDescription` shows `message`.
  public var errorDescription: String? { message }
}

/// One "Persistent work" profile as iTerm2's Dynamic Profiles read it (PLAN.md D26). The JSON
/// keys are iTerm2's own preference keys (seen in iTerm2 3.7.6 and in its Python module, a
/// read-only reference).
public struct PersistentProfile: Sendable, Hashable, Encodable {
  /// `"Guid"`: `muxfinder-persistent-<host id, lowercase>`, stable for the host.
  public var guid: String
  /// `"Name"`: `Persistent work – <host display name>` (an en dash).
  public var name: String
  /// `"Tags"`: `["muxFinder"]`.
  public var tags: [String]
  /// `"Custom Command"`: `"Yes"`, so the session runs `command` instead of the login shell.
  public var customCommand: String
  /// `"Command"`: `<helper> profile <host id>`.
  public var command: String
  /// `"Close Sessions On End"`: `true`, so the tab closes when the helper ends.
  public var closeSessionsOnEnd: Bool
  /// `"Dynamic Profile Parent Name"`: the profile it inherits from; absent (iTerm2's default
  /// profile) when the host sets none.
  public var parentName: String?

  /// iTerm2's keys.
  enum CodingKeys: String, CodingKey {
    /// `Guid`.
    case guid = "Guid"
    /// `Name`.
    case name = "Name"
    /// `Tags`.
    case tags = "Tags"
    /// `Custom Command`.
    case customCommand = "Custom Command"
    /// `Command`.
    case command = "Command"
    /// `Close Sessions On End`.
    case closeSessionsOnEnd = "Close Sessions On End"
    /// `Dynamic Profile Parent Name`.
    case parentName = "Dynamic Profile Parent Name"
  }

  /// Encodes every key, `Dynamic Profile Parent Name` only when set.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(guid, forKey: .guid)
    try container.encode(name, forKey: .name)
    try container.encode(tags, forKey: .tags)
    try container.encode(customCommand, forKey: .customCommand)
    try container.encode(command, forKey: .command)
    try container.encode(closeSessionsOnEnd, forKey: .closeSessionsOnEnd)
    try container.encodeIfPresent(parentName, forKey: .parentName)
  }
}

/// The contents of muxFinder's one dynamic profile file, `muxFinder.json` (PLAN.md D8, D26):
/// the profiles and the exact bytes to write.
public struct PersistentProfileDocument: Sendable, Hashable {
  /// The profiles, in host-list order.
  public let profiles: [PersistentProfile]
  /// The file's bytes: `{"Profiles": […]}`, pretty-printed with sorted keys and a final
  /// newline.
  public let data: Data

  /// Whether no host has a persistent profile; installing such a document removes the file
  /// (PLAN.md D26).
  public var isEmpty: Bool { profiles.isEmpty }
}

/// The generator of muxFinder's "Persistent work" dynamic profiles (PLAN.md D26): pure and
/// deterministic, from a host list and the helper's path to the bytes of `muxFinder.json`.
///
/// Each host with `persistentProfileEnabled` gets one profile, in list order, whatever its
/// `isEnabled` (discovery) setting: GUID `muxfinder-persistent-<host id, lowercase>`, name
/// `Persistent work – <display name>`, tag `muxFinder`, `"Custom Command": "Yes"`, `Command`
/// `<helper> profile <host id>` (`LaunchHelperPath.profileCommandLine(forHostID:)`), `"Close
/// Sessions On End": true`, and `Dynamic Profile Parent Name` only when the host sets a parent.
/// The command carries the host id alone: the helper reads the host's mode, destination, tmux
/// path and session name from `hosts.json` when the tab starts, so editing those needs no new
/// profile file. The helper's path must pass D2's character rule (`LaunchHelperPath`), so
/// iTerm2 splits the command into exactly three arguments; any other path is refused, and no
/// shell source is ever built.
public enum PersistentProfiles {
  /// The file's name in iTerm2's `DynamicProfiles` folder, the one iTerm2 file muxFinder owns.
  public static let fileName = "muxFinder.json"
  /// The prefix of every GUID muxFinder generates.
  public static let guidPrefix = "muxfinder-persistent-"
  /// The tag every generated profile carries.
  public static let tag = "muxFinder"
  /// The start of every generated profile's name (an en dash before the host's name).
  public static let namePrefix = "Persistent work \u{2013} "
  /// The largest document written or compared, in bytes.
  public static let maximumFileSize = 1024 * 1024

  /// The GUID of `hostID`'s profile.
  public static func guid(forHostID hostID: UUID) -> String {
    guidPrefix + LaunchToken(uuid: hostID).rawValue
  }

  /// The host id a GUID of this generator names, or `nil` for any other GUID.
  public static func hostID(fromGUID guid: String) -> UUID? {
    guard guid.hasPrefix(guidPrefix) else { return nil }
    return LaunchToken(String(guid.dropFirst(guidPrefix.count)))?.uuid
  }

  /// The name of `host`'s profile.
  public static func name(for host: HostConfig) -> String {
    namePrefix + host.displayName
  }

  /// `host`'s profile, running `helper`.
  public static func profile(for host: HostConfig, helper: LaunchHelperPath) -> PersistentProfile {
    PersistentProfile(
      guid: guid(forHostID: host.id),
      name: name(for: host),
      tags: [tag],
      customCommand: ITerm2API.ProfileProperty.customCommandEnabled,
      command: helper.profileCommandLine(forHostID: host.id),
      closeSessionsOnEnd: true,
      parentName: host.persistentProfileParentName)
  } // End of func profile(for:helper:)

  /// The document for `hosts`, with `helperPath` validated first (D2's rule); an unusable path
  /// throws `unsupportedHelperPath` and nothing is generated.
  public static func document(
    for hosts: HostList,
    helperPath: String
  ) throws(PersistentProfileError) -> PersistentProfileDocument {
    let helper: LaunchHelperPath
    do throws(LaunchHelperPathError) {
      helper = try LaunchHelperPath(validating: helperPath)
    } catch {
      throw .unsupportedHelperPath(error)
    }
    return try document(for: hosts, helper: helper)
  } // End of func document(for:helperPath:)

  /// The document for `hosts` running `helper`: one profile per host whose persistent profile
  /// is on, in list order.
  public static func document(
    for hosts: HostList,
    helper: LaunchHelperPath
  ) throws(PersistentProfileError) -> PersistentProfileDocument {
    let profiles = hosts.hosts.filter(\.persistentProfileEnabled).map {
      profile(for: $0, helper: helper)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard var data = try? encoder.encode(["Profiles": profiles]) else { throw .encodingFailed }
    data.append(0x0A)
    guard data.count <= maximumFileSize else { throw .documentTooLarge }
    return PersistentProfileDocument(profiles: profiles, data: data)
  } // End of func document(for:helper:)
}
