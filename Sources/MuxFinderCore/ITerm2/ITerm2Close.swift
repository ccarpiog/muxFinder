import Foundation

extension ITerm2API {
  /// `CloseRequest`: closes sessions, tabs or windows by id.
  ///
  /// muxFinder uses it only in the e2e harness, to close the launch tabs that harness opened
  /// itself (by the session ids `CreateTab` returned), never to detach tmux and never on a tab
  /// it did not create. Encoding follows iTerm2's Python module (`rpc.async_close`): the target
  /// is always present and `force` is always sent, even when `false`.
  public struct CloseRequest: Sendable, Hashable, ProtoEncodable {
    /// The member of the `target` oneof.
    public enum Target: Sendable, Hashable {
      /// `tabs` (1): `CloseTabs.tab_ids` (1).
      case tabs([String])
      /// `sessions` (2): `CloseSessions.session_ids` (1).
      case sessions([String])
      /// `windows` (3): `CloseWindows.window_ids` (1).
      case windows([String])
    }

    /// What to close.
    public var target: Target
    /// `force` (4): close without asking the user, even when a job is running.
    public var force: Bool

    /// Creates a request.
    public init(target: Target, force: Bool) {
      self.target = target
      self.force = force
    }

    /// Writes the target with its ids, then `force`, in field-number order.
    public func encode(to writer: inout ProtoWriter) {
      let (fieldNumber, ids): (Int, [String])
      switch target {
      case .tabs(let tabIDs): (fieldNumber, ids) = (1, tabIDs)
      case .sessions(let sessionIDs): (fieldNumber, ids) = (2, sessionIDs)
      case .windows(let windowIDs): (fieldNumber, ids) = (3, windowIDs)
      }
      writer.writeMessage(fieldNumber) { nested in
        for id in ids { nested.writeString(1, id) }
      }
      writer.writeBool(4, force)
    } // End of func encode(to:)
  } // End of struct CloseRequest

  /// `CloseResponse`: one status per requested id, in request order.
  public struct CloseResponse: Sendable, Hashable, ProtoDecodable {
    /// `CloseResponse.Status`.
    public enum Status: Sendable, Hashable {
      /// `OK` (0).
      case ok
      /// `NOT_FOUND` (1): no session, tab or window has the id.
      case notFound
      /// `USER_DECLINED` (2): the user cancelled iTerm2's confirmation.
      case userDeclined
      /// A value this build does not know.
      case unknown(Int)

      /// The status for a wire value.
      init(wireValue: Int) {
        switch wireValue {
        case 0: self = .ok
        case 1: self = .notFound
        case 2: self = .userDeclined
        default: self = .unknown(wireValue)
        }
      }
    } // End of enum Status

    /// `statuses` (1), a repeated enum.
    public var statuses: [Status]

    /// Creates a response.
    public init(statuses: [Status] = []) {
      self.statuses = statuses
    }

    /// Decodes a response. `statuses` is accepted both unpacked (one varint per value, as
    /// iTerm2 and the Python module write a `proto2` repeated enum) and packed (one
    /// length-delimited run), as every protobuf parser must accept both.
    public init(from reader: inout ProtoReader) throws {
      self.init()
      while let field = try reader.nextField() {
        switch (field.number, field.wireType) {
        case (1, .varint):
          statuses.append(Status(wireValue: try reader.readEnum()))
        case (1, .lengthDelimited):
          var packed = try reader.readNestedReader()
          while !packed.isAtEnd {
            statuses.append(Status(wireValue: try packed.readEnum()))
          }
        default:
          try reader.skip(field.wireType)
        }
      } // End of loop over fields
    } // End of init(from:)
  } // End of struct CloseResponse
}
