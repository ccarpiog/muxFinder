import Foundation

extension ITerm2API {
  /// Property names of a session for `SetPropertyRequest` and `GetPropertyRequest`.
  public enum SessionProperty {
    /// `"buried"`: whether the session is buried (in no tab, listed in
    /// `ListSessionsResponse.buried_sessions`). Its JSON value is `true` or `false`, the way the
    /// Python module's `Session.async_set_buried(_:)` sends it (`json.dumps`); iTerm2 3.7.6
    /// answers `GetProperty` with `1` or `0` (PLAN.md *Verified facts*, Phase 13a).
    public static let buried = "buried"
  }

  /// `SetPropertyRequest`: sets one property of a window or a session (PLAN.md Phase 13, S1).
  ///
  /// Encoding follows iTerm2's Python module (`rpc.async_set_property`): the target, `name` and
  /// `json_value` are always present, in field-number order (`window_id` 1, `name` 3,
  /// `json_value` 4, `session_id` 5).
  public struct SetPropertyRequest: Sendable, Hashable, ProtoEncodable {
    /// The member of the `identifier` oneof.
    public enum Target: Sendable, Hashable {
      /// `window_id` (1).
      case window(String)
      /// `session_id` (5).
      case session(String)
    }

    /// What the property belongs to.
    public var target: Target
    /// `name` (3): the property's name, such as `SessionProperty.buried`.
    public var name: String
    /// `json_value` (4): the new value as JSON text.
    public var jsonValue: String

    /// Creates a request.
    public init(target: Target, name: String, jsonValue: String) {
      self.target = target
      self.name = name
      self.jsonValue = jsonValue
    }

    /// The request that buries (`true`) or restores (`false`) the session `sessionID`, as the
    /// Python module's `Session.async_set_buried(_:)` builds it.
    public static func buried(_ buried: Bool, sessionID: String) -> SetPropertyRequest {
      SetPropertyRequest(
        target: .session(sessionID), name: SessionProperty.buried,
        jsonValue: ITerm2JSON.encode(buried))
    }

    /// Writes the target, the name and the value in field-number order.
    public func encode(to writer: inout ProtoWriter) {
      if case .window(let id) = target { writer.writeString(1, id) }
      writer.writeString(3, name)
      writer.writeString(4, jsonValue)
      if case .session(let id) = target { writer.writeString(5, id) }
    }
  } // End of struct SetPropertyRequest

  /// `SetPropertyResponse`.
  public struct SetPropertyResponse: Sendable, Hashable, ProtoDecodable {
    /// `SetPropertyResponse.Status`.
    public enum Status: Sendable, Hashable {
      /// `OK` (0).
      case ok
      /// `UNRECOGNIZED_NAME` (1).
      case unrecognizedName
      /// `INVALID_VALUE` (2).
      case invalidValue
      /// `INVALID_TARGET` (3): no window or session has the id.
      case invalidTarget
      /// `DEFERRED` (4).
      case deferred
      /// `IMPOSSIBLE` (5).
      case impossible
      /// `FAILED` (6).
      case failed
      /// A value this build does not know.
      case unknown(Int)

      /// The status for a wire value.
      init(wireValue: Int) {
        switch wireValue {
        case 0: self = .ok
        case 1: self = .unrecognizedName
        case 2: self = .invalidValue
        case 3: self = .invalidTarget
        case 4: self = .deferred
        case 5: self = .impossible
        case 6: self = .failed
        default: self = .unknown(wireValue)
        }
      } // End of init(wireValue:)
    } // End of enum Status

    /// `status` (1); `.ok` when absent, protobuf's default.
    public var status: Status

    /// Creates a response.
    public init(status: Status = .ok) {
      self.status = status
    }

    /// Decodes a response.
    public init(from reader: inout ProtoReader) throws {
      self.init()
      while let field = try reader.nextField() {
        switch (field.number, field.wireType) {
        case (1, .varint): status = Status(wireValue: try reader.readEnum())
        default: try reader.skip(field.wireType)
        }
      }
    }
  } // End of struct SetPropertyResponse

  /// `GetPropertyRequest`: reads one property of a window or a session.
  ///
  /// Encoding follows iTerm2's Python module (`rpc.async_get_property`): the target and `name`
  /// are present, in field-number order (`window_id` 1, `name` 2, `session_id` 3).
  public struct GetPropertyRequest: Sendable, Hashable, ProtoEncodable {
    /// The member of the `identifier` oneof.
    public enum Target: Sendable, Hashable {
      /// `window_id` (1).
      case window(String)
      /// `session_id` (3).
      case session(String)
    }

    /// What the property belongs to.
    public var target: Target
    /// `name` (2).
    public var name: String

    /// Creates a request.
    public init(target: Target, name: String) {
      self.target = target
      self.name = name
    }

    /// Writes the target and the name in field-number order.
    public func encode(to writer: inout ProtoWriter) {
      if case .window(let id) = target { writer.writeString(1, id) }
      writer.writeString(2, name)
      if case .session(let id) = target { writer.writeString(3, id) }
    }
  } // End of struct GetPropertyRequest

  /// `GetPropertyResponse`.
  public struct GetPropertyResponse: Sendable, Hashable, ProtoDecodable {
    /// `GetPropertyResponse.Status`.
    public enum Status: Sendable, Hashable {
      /// `OK` (0).
      case ok
      /// `UNRECOGNIZED_NAME` (1).
      case unrecognizedName
      /// `INVALID_TARGET` (2): no window or session has the id.
      case invalidTarget
      /// A value this build does not know.
      case unknown(Int)

      /// The status for a wire value.
      init(wireValue: Int) {
        switch wireValue {
        case 0: self = .ok
        case 1: self = .unrecognizedName
        case 2: self = .invalidTarget
        default: self = .unknown(wireValue)
        }
      }
    } // End of enum Status

    /// `status` (1); `.ok` when absent, protobuf's default.
    public var status: Status
    /// `json_value` (2): the value as JSON text, when iTerm2 sent one.
    public var jsonValue: String?

    /// Creates a response.
    public init(status: Status = .ok, jsonValue: String? = nil) {
      self.status = status
      self.jsonValue = jsonValue
    }

    /// Decodes a response.
    public init(from reader: inout ProtoReader) throws {
      self.init()
      while let field = try reader.nextField() {
        switch (field.number, field.wireType) {
        case (1, .varint): status = Status(wireValue: try reader.readEnum())
        case (2, .lengthDelimited): jsonValue = try reader.readString()
        default: try reader.skip(field.wireType)
        }
      }
    } // End of init(from:)
  } // End of struct GetPropertyResponse
}
