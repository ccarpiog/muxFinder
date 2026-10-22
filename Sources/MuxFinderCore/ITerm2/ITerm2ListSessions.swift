import Foundation

extension ITerm2API {
  /// `ListSessionsRequest`: asks for every window, tab and session. It has no fields.
  public struct ListSessionsRequest: Sendable, Hashable, ProtoEncodable {
    /// Creates the request.
    public init() {}

    /// Writes nothing: the request is an empty message.
    public func encode(to writer: inout ProtoWriter) {}
  }

  /// `ListSessionsResponse`: iTerm2's windows, tabs and sessions.
  public struct ListSessionsResponse: Sendable, Hashable, ProtoDecodable {
    /// `windows` (1).
    public var windows: [Window]
    /// `buried_sessions` (2): sessions that exist but are in no tab.
    public var buriedSessions: [SessionSummary]

    /// Creates a response.
    public init(windows: [Window] = [], buriedSessions: [SessionSummary] = []) {
      self.windows = windows
      self.buriedSessions = buriedSessions
    }

    /// The tabs of the tmux integration connection `connectionID`, in window order and then
    /// tab order.
    public func tabs(ofTmuxConnection connectionID: String) -> [Tab] {
      windows.flatMap(\.tabs).filter { $0.tmuxConnectionID == connectionID }
    }

    /// The window holding the tab whose split tree or minimized sessions contain `sessionID`,
    /// with that tab; `nil` when no tab holds it (it may be buried, or gone).
    public func placement(ofSession sessionID: String) -> (window: Window, tab: Tab)? {
      for window in windows {
        for tab in window.tabs
        where tab.sessions.contains(where: { $0.uniqueIdentifier == sessionID }) {
          return (window, tab)
        }
      }
      return nil
    }

    /// Every session id: those in tabs and the buried ones.
    public var allSessionIDs: Set<String> {
      let inTabs = windows.flatMap(\.tabs).flatMap(\.sessions)
      return Set((inTabs + buriedSessions).compactMap(\.uniqueIdentifier))
    }

    /// Decodes a response.
    public init(from reader: inout ProtoReader) throws {
      self.init()
      while let field = try reader.nextField() {
        switch (field.number, field.wireType) {
        case (1, .lengthDelimited): windows.append(try reader.readMessage(Window.self))
        case (2, .lengthDelimited):
          buriedSessions.append(try reader.readMessage(SessionSummary.self))
        default: try reader.skip(field.wireType)
        }
      }
    } // End of init(from:)
  } // End of struct ListSessionsResponse

  /// `ListSessionsResponse.Window`. `frame` (3) and `number` (4) are not modeled.
  public struct Window: Sendable, Hashable, ProtoDecodable {
    /// `window_id` (2).
    public var windowID: String?
    /// `tabs` (1), in the window's order.
    public var tabs: [Tab]

    /// Creates a window.
    public init(windowID: String? = nil, tabs: [Tab] = []) {
      self.windowID = windowID
      self.tabs = tabs
    }

    /// Decodes a window.
    public init(from reader: inout ProtoReader) throws {
      self.init()
      while let field = try reader.nextField() {
        switch (field.number, field.wireType) {
        case (1, .lengthDelimited): tabs.append(try reader.readMessage(Tab.self))
        case (2, .lengthDelimited): windowID = try reader.readString()
        default: try reader.skip(field.wireType)
        }
      }
    }
  } // End of struct Window

  /// `ListSessionsResponse.Tab`.
  public struct Tab: Sendable, Hashable, ProtoDecodable {
    /// `tab_id` (2). A string here, although `CreateTabResponse.tab_id` is an `int32`.
    public var tabID: String?
    /// `root` (3): the tab's split tree.
    public var root: SplitTreeNode?
    /// `tmux_window_id` (4): set when the tab shows a tmux window.
    public var tmuxWindowID: String?
    /// `tmux_connection_id` (5): the tmux integration connection the tab belongs to.
    public var tmuxConnectionID: String?
    /// `minimized_sessions` (6): sessions hidden while another pane of the tab is maximized.
    public var minimizedSessions: [SessionSummary]

    /// Creates a tab.
    public init(
      tabID: String? = nil,
      root: SplitTreeNode? = nil,
      tmuxWindowID: String? = nil,
      tmuxConnectionID: String? = nil,
      minimizedSessions: [SessionSummary] = []
    ) {
      self.tabID = tabID
      self.root = root
      self.tmuxWindowID = tmuxWindowID
      self.tmuxConnectionID = tmuxConnectionID
      self.minimizedSessions = minimizedSessions
    } // End of init(tabID:root:tmuxWindowID:tmuxConnectionID:minimizedSessions:)

    /// Every session in the tab: the split tree's, depth first in link order, then the
    /// minimized ones.
    public var sessions: [SessionSummary] {
      (root?.sessions ?? []) + minimizedSessions
    }

    /// The `tmux_window_id` iTerm2 sends for a tab that shows no tmux window (iTerm2 3.7.6
    /// sends it on every ordinary tab, without a `tmux_connection_id`).
    public static let noTmuxWindowID = "-1"

    /// Whether the tab belongs to a tmux integration connection: it has a connection id, or a
    /// tmux window id other than `noTmuxWindowID`.
    public var isTmuxTab: Bool {
      if let tmuxConnectionID, !tmuxConnectionID.isEmpty { return true }
      guard let tmuxWindowID else { return false }
      return !tmuxWindowID.isEmpty && tmuxWindowID != Self.noTmuxWindowID
    }

    /// Decodes a tab. Repeated occurrences of `root` merge into one split tree.
    public init(from reader: inout ProtoReader) throws {
      self.init()
      var rootOccurrences = ProtoMessageField()
      while let field = try reader.nextField() {
        switch (field.number, field.wireType) {
        case (2, .lengthDelimited): tabID = try reader.readString()
        case (3, .lengthDelimited): try rootOccurrences.merge(from: &reader)
        case (4, .lengthDelimited): tmuxWindowID = try reader.readString()
        case (5, .lengthDelimited): tmuxConnectionID = try reader.readString()
        case (6, .lengthDelimited):
          minimizedSessions.append(try reader.readMessage(SessionSummary.self))
        default: try reader.skip(field.wireType)
        }
      } // End of loop over fields
      root = try rootOccurrences.decode(SplitTreeNode.self)
    } // End of init(from:)
  } // End of struct Tab

  /// `SplitTreeNode`: a splitter whose children are sessions or further splitters.
  public struct SplitTreeNode: Sendable, Hashable, ProtoDecodable {
    /// `SplitTreeNode.SplitTreeLink`: one child, a session or a nested splitter.
    public enum Link: Sendable, Hashable {
      /// `session` (1).
      case session(SessionSummary)
      /// `node` (2).
      case node(SplitTreeNode)
    }

    /// `vertical` (1): whether the divider lines are vertical (children side by side).
    public var vertical: Bool
    /// `links` (2), in order. A link with neither child (iTerm2 never sends one) is dropped.
    public var links: [Link]

    /// Creates a split tree node.
    public init(vertical: Bool = false, links: [Link] = []) {
      self.vertical = vertical
      self.links = links
    }

    /// Every session under this node, depth first in link order.
    public var sessions: [SessionSummary] {
      links.flatMap { link -> [SessionSummary] in
        switch link {
        case .session(let session): return [session]
        case .node(let node): return node.sessions
        }
      }
    }

    /// Decodes a node.
    public init(from reader: inout ProtoReader) throws {
      self.init()
      while let field = try reader.nextField() {
        switch (field.number, field.wireType) {
        case (1, .varint): vertical = try reader.readBool()
        case (2, .lengthDelimited):
          var nested = try reader.readNestedReader()
          if let link = try Self.decodeLink(from: &nested) { links.append(link) }
        default: try reader.skip(field.wireType)
        }
      }
    } // End of init(from:)

    /// Decodes a `SplitTreeLink`. Its `child` oneof keeps the last member seen, with repeated
    /// occurrences of that member merged.
    private static func decodeLink(from reader: inout ProtoReader) throws -> Link? {
      var child = ProtoOneof()
      while let field = try reader.nextField() {
        switch (field.number, field.wireType) {
        case (1, .lengthDelimited), (2, .lengthDelimited):
          try child.mergeMessage(field.number, from: &reader)
        default: try reader.skip(field.wireType)
        }
      }
      switch child.fieldNumber {
      case 1: return try child.message.decode(SessionSummary.self).map(Link.session)
      case 2: return try child.message.decode(SplitTreeNode.self).map(Link.node)
      default: return nil
      }
    } // End of func decodeLink(from:)
  } // End of struct SplitTreeNode

  /// `SessionSummary`. `frame` (2) and `grid_size` (3) are not modeled. Titles are terminal
  /// content: never log them.
  public struct SessionSummary: Sendable, Hashable, ProtoDecodable {
    /// `unique_identifier` (1): the session id used by every other call.
    public var uniqueIdentifier: String?
    /// `title` (4).
    public var title: String?

    /// Creates a session summary.
    public init(uniqueIdentifier: String? = nil, title: String? = nil) {
      self.uniqueIdentifier = uniqueIdentifier
      self.title = title
    }

    /// Decodes a session summary.
    public init(from reader: inout ProtoReader) throws {
      self.init()
      while let field = try reader.nextField() {
        switch (field.number, field.wireType) {
        case (1, .lengthDelimited): uniqueIdentifier = try reader.readString()
        case (4, .lengthDelimited): title = try reader.readString()
        default: try reader.skip(field.wireType)
        }
      }
    }
  } // End of struct SessionSummary
}
