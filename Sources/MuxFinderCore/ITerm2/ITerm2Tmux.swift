import Foundation

extension ITerm2API {
  /// `TmuxRequest`: the members of its `payload` oneof that muxFinder uses.
  public enum TmuxRequest: Sendable, Hashable, ProtoEncodable {
    /// `list_connections` (1): every tmux integration connection.
    case listConnections
    /// `send_command` (2): runs a tmux command on a connection and returns its output.
    case sendCommand(connectionID: String, command: String)

    /// Writes the payload. `send_command` always carries both fields, as the Python module
    /// sends them.
    public func encode(to writer: inout ProtoWriter) {
      switch self {
      case .listConnections:
        writer.writeMessage(1) { _ in }
      case .sendCommand(let connectionID, let command):
        writer.writeMessage(2) { nested in
          nested.writeString(1, connectionID)
          nested.writeString(2, command)
        }
      }
    } // End of func encode(to:)
  } // End of enum TmuxRequest

  /// `TmuxResponse`.
  public struct TmuxResponse: Sendable, Hashable, ProtoDecodable {
    /// The members of the `payload` oneof that muxFinder uses.
    public enum Payload: Sendable, Hashable {
      /// `list_connections` (1).
      case listConnections([TmuxConnection])
      /// `send_command` (2): `output` (1), the command's output; `nil` when absent.
      case sendCommand(output: String?)
    }

    /// `TmuxResponse.Status`.
    public enum Status: Sendable, Hashable {
      /// `OK` (0).
      case ok
      /// `INVALID_REQUEST` (1).
      case invalidRequest
      /// `INVALID_CONNECTION_ID` (2).
      case invalidConnectionID
      /// `INVALID_WINDOW_ID` (3).
      case invalidWindowID
      /// A value this build does not know.
      case unknown(Int)

      /// The status for a wire value.
      init(wireValue: Int) {
        switch wireValue {
        case 0: self = .ok
        case 1: self = .invalidRequest
        case 2: self = .invalidConnectionID
        case 3: self = .invalidWindowID
        default: self = .unknown(wireValue)
        }
      }
    } // End of enum Status

    /// The payload; `nil` when absent or another member of the oneof (`set_window_visible` (3),
    /// `create_window` (5)).
    public var payload: Payload?
    /// `status` (4); `.ok` when absent, protobuf's default.
    public var status: Status

    /// Creates a response.
    public init(payload: Payload? = nil, status: Status = .ok) {
      self.payload = payload
      self.status = status
    }

    /// Decodes a response. The `payload` oneof keeps the last member seen, with repeated
    /// occurrences of that member merged.
    public init(from reader: inout ProtoReader) throws {
      self.init()
      var payloadMember = ProtoOneof()
      while let field = try reader.nextField() {
        switch (field.number, field.wireType) {
        case (1, .lengthDelimited), (2, .lengthDelimited), (3, .lengthDelimited),
          (5, .lengthDelimited):
          try payloadMember.mergeMessage(field.number, from: &reader)
        case (4, .varint): status = Status(wireValue: try reader.readEnum())
        default: try reader.skip(field.wireType)
        }
      } // End of loop over fields
      let message = payloadMember.message
      switch payloadMember.fieldNumber {
      case 1:
        payload = try message.decode(with: Self.decodeConnections).map(Payload.listConnections)
      case 2:
        payload = try message.decode(with: Self.decodeOutput).map { .sendCommand(output: $0) }
      default:
        payload = nil
      }
    } // End of init(from:)

    /// Decodes `TmuxResponse.ListConnections`: `connections` (1).
    private static func decodeConnections(
      from reader: inout ProtoReader
    ) throws -> [TmuxConnection] {
      var connections: [TmuxConnection] = []
      while let field = try reader.nextField() {
        switch (field.number, field.wireType) {
        case (1, .lengthDelimited): connections.append(try reader.readMessage(TmuxConnection.self))
        default: try reader.skip(field.wireType)
        }
      }
      return connections
    } // End of func decodeConnections(from:)

    /// Decodes `TmuxResponse.SendCommand`: `output` (1).
    private static func decodeOutput(from reader: inout ProtoReader) throws -> String? {
      var output: String?
      while let field = try reader.nextField() {
        switch (field.number, field.wireType) {
        case (1, .lengthDelimited): output = try reader.readString()
        default: try reader.skip(field.wireType)
        }
      }
      return output
    }
  } // End of struct TmuxResponse

  /// `TmuxResponse.ListConnections.Connection`: one tmux integration (`tmux -CC`) connection.
  public struct TmuxConnection: Sendable, Hashable, ProtoDecodable {
    /// `connection_id` (1).
    public var connectionID: String?
    /// `owning_session_id` (2): the iTerm2 session running the `tmux -CC` client.
    public var owningSessionID: String?

    /// Creates a connection.
    public init(connectionID: String? = nil, owningSessionID: String? = nil) {
      self.connectionID = connectionID
      self.owningSessionID = owningSessionID
    }

    /// Decodes a connection.
    public init(from reader: inout ProtoReader) throws {
      self.init()
      while let field = try reader.nextField() {
        switch (field.number, field.wireType) {
        case (1, .lengthDelimited): connectionID = try reader.readString()
        case (2, .lengthDelimited): owningSessionID = try reader.readString()
        default: try reader.skip(field.wireType)
        }
      }
    }
  } // End of struct TmuxConnection
}
