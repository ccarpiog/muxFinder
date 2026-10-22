import Foundation

/// Typed messages of iTerm2's API (`api.proto`, `proto2`), limited to the calls muxFinder makes.
///
/// Field numbers are protocol facts looked up in iTerm2's installed Python module and recorded
/// in PLAN.md *Verified facts*. Requests encode in field-number order, byte for byte as the
/// Python module's `SerializeToString` does; responses decode leniently (unknown fields are
/// skipped, unknown enum values are kept as `unknown`) and follow protobuf's merge rules (see
/// `ProtoDecodable`).
public enum ITerm2API {}

extension ITerm2API {
  /// `ClientOriginatedMessage`: one request sent to iTerm2.
  public struct ClientOriginatedMessage: Sendable, Hashable, ProtoEncodable {
    /// The request in the message's `submessage` oneof.
    public enum Request: Sendable, Hashable {
      /// `list_sessions_request` (106).
      case listSessions(ListSessionsRequest)
      /// `create_tab_request` (108).
      case createTab(CreateTabRequest)
      /// `activate_request` (114).
      case activate(ActivateRequest)
      /// `list_profiles_request` (118).
      case listProfiles(ListProfilesRequest)
      /// `tmux_request` (124).
      case tmux(TmuxRequest)
      /// `close_request` (131).
      case close(CloseRequest)
    }

    /// `id` (1): echoed in the response so it can be matched to this request.
    public var id: Int64
    /// The request.
    public var request: Request

    /// Creates a request message.
    public init(id: Int64, request: Request) {
      self.id = id
      self.request = request
    }

    /// Writes `id` (always present, as the Python module always sets it) and the request.
    public func encode(to writer: inout ProtoWriter) {
      writer.writeInt64(1, id)
      switch request {
      case .listSessions(let message): writer.writeMessage(106, message)
      case .createTab(let message): writer.writeMessage(108, message)
      case .activate(let message): writer.writeMessage(114, message)
      case .listProfiles(let message): writer.writeMessage(118, message)
      case .tmux(let message): writer.writeMessage(124, message)
      case .close(let message): writer.writeMessage(131, message)
      }
    }
  } // End of struct ClientOriginatedMessage

  /// `ServerOriginatedMessage`: one response (or notification) from iTerm2.
  public struct ServerOriginatedMessage: Sendable, Hashable, ProtoDecodable {
    /// The member of the message's `submessage` oneof.
    public enum Response: Sendable, Hashable {
      /// `error` (2): iTerm2 rejected the request; the text is iTerm2's.
      case error(String)
      /// `list_sessions_response` (106).
      case listSessions(ListSessionsResponse)
      /// `create_tab_response` (108).
      case createTab(CreateTabResponse)
      /// `activate_response` (114).
      case activate(ActivateResponse)
      /// `list_profiles_response` (118).
      case listProfiles(ListProfilesResponse)
      /// `tmux_response` (124).
      case tmux(TmuxResponse)
      /// `close_response` (131).
      case close(CloseResponse)
      /// Any other member of the oneof: `notification` (1000) or a response type this package
      /// does not model. Its contents are skipped.
      case unsupported(fieldNumber: Int)
    }

    /// The field numbers of the `submessage` oneof's embedded-message members in `api.proto`
    /// (iterm2 module 2.11): every response type, 100...133, and `notification` (1000). The only
    /// other member is the string `error` (2). Any other field number is not in the proto: it is
    /// skipped like every unknown field and never changes the response.
    static let submessageMessageFieldNumbers: Set<Int> = Set(100...133).union([1000])

    /// `id` (1): the id of the request this answers; `nil` for notifications.
    public var id: Int64?
    /// The response; `nil` if the message carries none.
    public var response: Response?

    /// Creates a response message.
    public init(id: Int64? = nil, response: Response? = nil) {
      self.id = id
      self.response = response
    }

    /// Decodes a response message. The last member of the oneof wins; repeated occurrences of
    /// the same response merge, as protobuf merges them.
    public init(from reader: inout ProtoReader) throws {
      var id: Int64?
      var error = ""
      var submessage = ProtoOneof()
      while let field = try reader.nextField() {
        switch (field.number, field.wireType) {
        case (1, .varint): id = try reader.readInt64()
        case (2, .lengthDelimited):
          error = try reader.readString()
          submessage.selectScalar(2)
        case (let number, .lengthDelimited)
        where Self.submessageMessageFieldNumbers.contains(number):
          try submessage.mergeMessage(number, from: &reader)
        default:
          try reader.skip(field.wireType)
        }
      } // End of loop over fields
      self.init(id: id, response: try Self.response(of: submessage, error: error))
    } // End of init(from:)

    /// The response the oneof's last member holds: decoded when this package models it,
    /// `unsupported` when it does not, `nil` when no member appeared.
    private static func response(of submessage: ProtoOneof, error: String) throws -> Response? {
      let message = submessage.message
      switch submessage.fieldNumber {
      case nil: return nil
      case 2: return .error(error)
      case 106: return try message.decode(ListSessionsResponse.self).map(Response.listSessions)
      case 108: return try message.decode(CreateTabResponse.self).map(Response.createTab)
      case 114: return try message.decode(ActivateResponse.self).map(Response.activate)
      case 118: return try message.decode(ListProfilesResponse.self).map(Response.listProfiles)
      case 124: return try message.decode(TmuxResponse.self).map(Response.tmux)
      case 131: return try message.decode(CloseResponse.self).map(Response.close)
      case let number?: return .unsupported(fieldNumber: number)
      }
    } // End of func response(of:error:)
  } // End of struct ServerOriginatedMessage
}
