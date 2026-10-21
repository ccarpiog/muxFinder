import Foundation

extension ITerm2API {
  /// `ActivateRequest`: brings a window, tab or session forward, and optionally iTerm2 itself.
  ///
  /// Encoding follows iTerm2's Python module (`rpc.async_activate`): the three flags are always
  /// sent, even when `false`, and the app options are sent only when set.
  public struct ActivateRequest: Sendable, Hashable, ProtoEncodable {
    /// The member of the `identifier` oneof.
    public enum Target: Sendable, Hashable {
      /// `window_id` (1).
      case window(String)
      /// `tab_id` (2).
      case tab(String)
      /// `session_id` (3).
      case session(String)
    }

    /// `ActivateRequest.App`: how to activate iTerm2 itself.
    public struct AppOptions: Sendable, Hashable, ProtoEncodable {
      /// `raise_all_windows` (1).
      public var raiseAllWindows: Bool
      /// `ignoring_other_apps` (2).
      public var ignoringOtherApps: Bool

      /// Creates app options.
      public init(raiseAllWindows: Bool = false, ignoringOtherApps: Bool = false) {
        self.raiseAllWindows = raiseAllWindows
        self.ignoringOtherApps = ignoringOtherApps
      }

      /// Writes only the options that are `true` (as the Python module does).
      public func encode(to writer: inout ProtoWriter) {
        if raiseAllWindows { writer.writeBool(1, true) }
        if ignoringOtherApps { writer.writeBool(2, true) }
      }
    } // End of struct AppOptions

    /// What to activate; `nil` with `activateApp` set activates only the app.
    public var target: Target?
    /// `order_window_front` (4).
    public var orderWindowFront: Bool
    /// `select_tab` (5).
    public var selectTab: Bool
    /// `select_session` (6).
    public var selectSession: Bool
    /// `activate_app` (7); `nil` leaves iTerm2's activation alone.
    public var activateApp: AppOptions?

    /// Creates a request.
    public init(
      target: Target?,
      orderWindowFront: Bool,
      selectTab: Bool,
      selectSession: Bool,
      activateApp: AppOptions? = nil
    ) {
      self.target = target
      self.orderWindowFront = orderWindowFront
      self.selectTab = selectTab
      self.selectSession = selectSession
      self.activateApp = activateApp
    } // End of init(target:orderWindowFront:selectTab:selectSession:activateApp:)

    /// Writes the target, the three flags and the app options, in field-number order.
    public func encode(to writer: inout ProtoWriter) {
      switch target {
      case .window(let id): writer.writeString(1, id)
      case .tab(let id): writer.writeString(2, id)
      case .session(let id): writer.writeString(3, id)
      case nil: break
      }
      writer.writeBool(4, orderWindowFront)
      writer.writeBool(5, selectTab)
      writer.writeBool(6, selectSession)
      if let activateApp { writer.writeMessage(7, activateApp) }
    } // End of func encode(to:)
  } // End of struct ActivateRequest

  /// `ActivateResponse`.
  public struct ActivateResponse: Sendable, Hashable, ProtoDecodable {
    /// `ActivateResponse.Status`.
    public enum Status: Sendable, Hashable {
      /// `OK` (0).
      case ok
      /// `BAD_IDENTIFIER` (1).
      case badIdentifier
      /// `INVALID_OPTION` (2).
      case invalidOption
      /// A value this build does not know.
      case unknown(Int)

      /// The status for a wire value.
      init(wireValue: Int) {
        switch wireValue {
        case 0: self = .ok
        case 1: self = .badIdentifier
        case 2: self = .invalidOption
        default: self = .unknown(wireValue)
        }
      }
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
  } // End of struct ActivateResponse
}
