import Foundation

extension ITerm2API {
  /// `ProfileProperty`: one profile setting, a key and its value as JSON text.
  public struct ProfileProperty: Sendable, Hashable, ProtoEncodable, ProtoDecodable {
    /// Profile keys muxFinder uses. These are iTerm2's own preference keys.
    public enum Key {
      /// `"Custom Command"`: `"No"`, `"Yes"` or `"SSH"`, as a JSON string.
      public static let customCommand = "Custom Command"
      /// `"Command"`: the command line, as a JSON string.
      public static let command = "Command"
      /// `"Close Sessions On End"`: a JSON bool.
      public static let closeSessionsOnEnd = "Close Sessions On End"
      /// `"Name"`: the profile name, as a JSON string.
      public static let name = "Name"
      /// `"Guid"`: the profile GUID, as a JSON string.
      public static let guid = "Guid"
    }

    /// The `"Custom Command"` value that makes the session run `"Command"` instead of the login
    /// shell.
    public static let customCommandEnabled = "Yes"

    /// `key` (1).
    public var key: String
    /// `json_value` (2): the value as JSON text, for example `"\"Yes\""` or `"true"`.
    public var jsonValue: String

    /// Creates a property from a key and JSON text.
    public init(key: String, jsonValue: String) {
      self.key = key
      self.jsonValue = jsonValue
    }

    /// The properties that make a new session run `command` instead of the login shell:
    /// `"Custom Command"` = `"Yes"`, then `"Command"` = the command, in the order iTerm2's Python
    /// module sends them for `Window.async_create(command:)`.
    public static func customCommand(_ command: String) -> [ProfileProperty] {
      [
        ProfileProperty(key: Key.customCommand, jsonValue: ITerm2JSON.encode(customCommandEnabled)),
        ProfileProperty(key: Key.command, jsonValue: ITerm2JSON.encode(command)),
      ]
    }

    /// The property that decides whether the session's tab closes when its command ends.
    public static func closeSessionsOnEnd(_ value: Bool) -> ProfileProperty {
      ProfileProperty(key: Key.closeSessionsOnEnd, jsonValue: ITerm2JSON.encode(value))
    }

    /// Writes `key` and `json_value`, both always present (the Python module always sets both).
    public func encode(to writer: inout ProtoWriter) {
      writer.writeString(1, key)
      writer.writeString(2, jsonValue)
    }

    /// Decodes a property; missing fields read as empty strings.
    public init(from reader: inout ProtoReader) throws {
      self.init(key: "", jsonValue: "")
      while let field = try reader.nextField() {
        switch (field.number, field.wireType) {
        case (1, .lengthDelimited): key = try reader.readString()
        case (2, .lengthDelimited): jsonValue = try reader.readString()
        default: try reader.skip(field.wireType)
        }
      }
    }
  } // End of struct ProfileProperty

  /// `CreateTabRequest`: opens a tab in a window, or a new window. The deprecated `command` (4)
  /// field is not offered; use `ProfileProperty.customCommand(_:)` instead.
  public struct CreateTabRequest: Sendable, Hashable, ProtoEncodable {
    /// `profile_name` (1); `nil` for the default profile.
    public var profileName: String?
    /// `window_id` (2); `nil` opens a new window.
    public var windowID: String?
    /// `tab_index` (3): position in the window, 0 first; `nil` for iTerm2's default.
    public var tabIndex: UInt32?
    /// `custom_profile_properties` (5): overrides applied to this session only, in order.
    public var customProfileProperties: [ProfileProperty]

    /// Creates a request.
    public init(
      profileName: String? = nil,
      windowID: String? = nil,
      tabIndex: UInt32? = nil,
      customProfileProperties: [ProfileProperty] = []
    ) {
      self.profileName = profileName
      self.windowID = windowID
      self.tabIndex = tabIndex
      self.customProfileProperties = customProfileProperties
    } // End of init(profileName:windowID:tabIndex:customProfileProperties:)

    /// Writes the fields that are set, in field-number order.
    public func encode(to writer: inout ProtoWriter) {
      if let profileName { writer.writeString(1, profileName) }
      if let windowID { writer.writeString(2, windowID) }
      if let tabIndex { writer.writeUInt32(3, tabIndex) }
      for property in customProfileProperties { writer.writeMessage(5, property) }
    }
  } // End of struct CreateTabRequest

  /// `CreateTabResponse`.
  public struct CreateTabResponse: Sendable, Hashable, ProtoDecodable {
    /// `CreateTabResponse.Status`.
    public enum Status: Sendable, Hashable {
      /// `OK` (0).
      case ok
      /// `INVALID_PROFILE_NAME` (1).
      case invalidProfileName
      /// `INVALID_WINDOW_ID` (2).
      case invalidWindowID
      /// `INVALID_TAB_INDEX` (3).
      case invalidTabIndex
      /// `MISSING_SUBSTITUTION` (4).
      case missingSubstitution
      /// A value this build does not know.
      case unknown(Int)

      /// The status for a wire value.
      init(wireValue: Int) {
        switch wireValue {
        case 0: self = .ok
        case 1: self = .invalidProfileName
        case 2: self = .invalidWindowID
        case 3: self = .invalidTabIndex
        case 4: self = .missingSubstitution
        default: self = .unknown(wireValue)
        }
      }
    } // End of enum Status

    /// `status` (1); `.ok` when absent, protobuf's default (the first enum value).
    public var status: Status
    /// `window_id` (2): the window that holds the new tab.
    public var windowID: String?
    /// `tab_id` (3). An `int32` here, although `ListSessionsResponse.Tab.tab_id` is a string.
    public var tabID: Int32?
    /// `session_id` (4): the new tab's session.
    public var sessionID: String?

    /// Creates a response.
    public init(
      status: Status = .ok,
      windowID: String? = nil,
      tabID: Int32? = nil,
      sessionID: String? = nil
    ) {
      self.status = status
      self.windowID = windowID
      self.tabID = tabID
      self.sessionID = sessionID
    } // End of init(status:windowID:tabID:sessionID:)

    /// Decodes a response.
    public init(from reader: inout ProtoReader) throws {
      self.init()
      while let field = try reader.nextField() {
        switch (field.number, field.wireType) {
        case (1, .varint): status = Status(wireValue: try reader.readEnum())
        case (2, .lengthDelimited): windowID = try reader.readString()
        case (3, .varint): tabID = try reader.readInt32()
        case (4, .lengthDelimited): sessionID = try reader.readString()
        default: try reader.skip(field.wireType)
        }
      }
    } // End of init(from:)
  } // End of struct CreateTabResponse
}
