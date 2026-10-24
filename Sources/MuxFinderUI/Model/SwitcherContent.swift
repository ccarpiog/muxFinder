import Foundation
import MuxFinderCore

/// Everything the session switcher shows (PLAN.md D32, Phase I-3b), computed from the refresh
/// engine's state, the switcher's search text and selection, the per-session activities and
/// what the switcher's own actions left behind. A pure value, so every rule here is tested
/// without SwiftUI.
///
/// - **Rows:** a flat list of the **live** sessions in the popover's order (host order, then
///   session order), each one the popover's `SessionRow` (its state indicator, detail text,
///   badge and activity); stale sessions are left out, so an unreachable host lists nothing.
/// - **Filter:** the popover's search rule over host and session names
///   (`PopoverContent.matches(_:query:)`: a host whose name matches keeps all its sessions,
///   otherwise only the sessions whose names match; case, diacritics and surrounding spaces
///   ignored).
/// - **Pinned rows** come first: the failures of actions the switcher started that ended while
///   it was closed (shown at its next opening), then the sessions of its actions that are not
///   listed (yet), such as a session New session just created. A pinned session is not
///   repeated below.
/// - **New session** is always the last row: "New session…", or "New session “<text>”…" with
///   the name filled in when the filter text is a valid session name and no live session has
///   exactly that name.
/// - **Host lines:** a muted line under the list for each host that is still checking or whose
///   last check failed ("Saturno: checking…", "Sirio: unreachable"), so missing sessions are
///   explained.
/// - **Placeholder:** while the host list loads, and with no host turned on (the popover's,
///   with "Open Settings"); then nothing is listed and there is no New session row.
/// - **Selection:** the given item while it is listed, otherwise the first item.
public struct SwitcherContent: Sendable, Hashable {
  /// One selectable row.
  public enum Item: Sendable, Hashable {
    /// A session row (pinned or listed).
    case session(SessionKey)
    /// The New session row.
    case newSession
  }

  /// The last row: New session, with the name the filter text gives it, if any.
  public struct NewSessionRow: Sendable, Hashable {
    /// The session name New session starts with: the filter text when it is a valid session
    /// name (trimmed) and no live session has exactly that name; `nil` otherwise.
    public var prefill: String?
    /// Whether the keyboard selection is on this row.
    public var isSelected: Bool

    /// "New session “<name>”…" with a prefill, else "New session…".
    public var title: String {
      prefill.map { "New session “\($0)”…" } ?? "New session…"
    }

    /// The VoiceOver label: the title.
    public var accessibilityLabel: String { title }
  }

  /// A muted line under the list for a host whose sessions are not listed.
  public struct HostLine: Sendable, Hashable, Identifiable {
    /// The host's id.
    public var id: UUID
    /// "Saturno: checking…", "Sirio: unreachable", "Saturno: sign-in needed".
    public var text: String
    /// The host status's tone (its dot; never red, PLAN.md D22).
    public var tone: HostStatusLabel.Tone
  }

  /// What replaces the list while the host list loads, or with no host turned on.
  public var placeholder: PopoverContent.Placeholder?
  /// Sessions that vanished or changed between the listing and an action, newest first (the
  /// popover's banners).
  public var banners: [SessionBanner]
  /// The pinned rows, at the top: carried failures, then the switcher's actions on sessions
  /// not listed.
  public var pinned: [SessionRow]
  /// The live sessions after filtering, without the pinned ones.
  public var rows: [SessionRow]
  /// The New session row; `nil` with a placeholder.
  public var newSession: NewSessionRow?
  /// The muted lines for hosts still checking or whose last check failed, in host order.
  public var hostLines: [HostLine]
  /// What the list says when it lists no session: "No live sessions." or "No session
  /// matches “…”."; `nil` when it lists any (or shows a placeholder).
  public var emptyText: String?
  /// The selected item (`nil` only when nothing is selectable).
  public var selection: Item?

  /// "No live sessions." when nothing is listed without a filter.
  public static let noLiveSessionsText = "No live sessions."

  /// What the list says when the filter `query` matches no session.
  public static func noMatchesText(_ query: String) -> String {
    "No session matches “\(query)”."
  }

  /// The selectable items, top to bottom: the pinned rows, the listed rows, New session.
  public var items: [Item] {
    var items = pinned.map { Item.session($0.key) } + rows.map { Item.session($0.key) }
    if newSession != nil { items.append(.newSession) }
    return items
  }

  /// The content for `state` (`nil` while loading) with the switcher's `query` and
  /// `selection`, the sessions' `activities` and `notes`, relative times seen at `now`, the
  /// `banners`, and the sessions muxFinder attached or found here (`attachedHere`).
  /// `carried` lists the sessions whose failure is shown at the top (newest first; only those
  /// still failed count), `actionKeys` the sessions of the switcher's actions (pinned when
  /// not listed), and `targets` those sessions as listed when their action started (the row
  /// of a session the engine does not list).
  public init(
    state: RefreshState?,
    hostList: HostListStatus?,
    query: String,
    selection: Item?,
    activities: [SessionKey: SessionActivity],
    now: Date,
    notes: [SessionKey: String] = [:],
    banners: [SessionBanner] = [],
    attachedHere: Set<SessionKey> = [],
    carried: [SessionKey] = [],
    actionKeys: [SessionKey] = [],
    targets: [SessionKey: AttachTarget] = [:]
  ) {
    self.banners = banners
    pinned = []
    rows = []
    hostLines = []
    newSession = nil
    emptyText = nil
    self.selection = nil
    guard let state else {
      placeholder = .loading
      return
    }
    guard !state.hosts.isEmpty else {
      placeholder = .noHostsEnabled
      return
    }
    placeholder = nil
    let all = PopoverContent(
      state: state, hostList: hostList, query: "", activities: activities, selection: nil,
      now: now, notes: notes, attachedHere: attachedHere
    ).sections.flatMap(\.rows)
    let live = all.filter { !$0.isStale }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    pinned = Self.pinnedRows(
      all: all, live: live, carried: carried, actionKeys: actionKeys, targets: targets,
      activities: activities, notes: notes)
    pinned = pinned.filter { Self.passes($0, query: trimmed) }
    let pinnedKeys = Set(pinned.map(\.key))
    rows = live.filter { !pinnedKeys.contains($0.key) && Self.passes($0, query: trimmed) }
    newSession = NewSessionRow(prefill: Self.prefill(trimmed, live: live), isSelected: false)
    if pinned.isEmpty && rows.isEmpty {
      emptyText = trimmed.isEmpty ? Self.noLiveSessionsText : Self.noMatchesText(trimmed)
    }
    hostLines = state.hosts.compactMap(Self.hostLine(for:))
    select(selection)
  } // End of init(state:hostList:query:selection:activities:now:notes:banners:…)

  /// Whether `row` passes the filter `query` (trimmed; empty lets everything pass): its host's
  /// name or its own name contains it (the popover's rule).
  static func passes(_ row: SessionRow, query: String) -> Bool {
    query.isEmpty || PopoverContent.matches(row.hostName, query: query)
      || PopoverContent.matches(row.name, query: query)
  }

  /// The New session row's name for the filter text `query` (trimmed): the valid session name
  /// it gives (`Validation.sessionName(_:)`) when no live session has exactly that name.
  static func prefill(_ query: String, live: [SessionRow]) -> String? {
    guard let name = try? Validation.sessionName(query),
      !live.contains(where: { $0.name == name })
    else { return nil }
    return name
  }

  /// The pinned rows: each carried session whose activity is still a failure (its row as the
  /// engine lists it, stale or live, else made from its target), then each action's session
  /// that is not listed live, with its activity.
  static func pinnedRows(
    all: [SessionRow],
    live: [SessionRow],
    carried: [SessionKey],
    actionKeys: [SessionKey],
    targets: [SessionKey: AttachTarget],
    activities: [SessionKey: SessionActivity],
    notes: [SessionKey: String]
  ) -> [SessionRow] {
    var pinned: [SessionRow] = []
    var seen: Set<SessionKey> = []
    for key in carried where activities[key]?.problem != nil && !seen.contains(key) {
      guard
        let row = all.first(where: { $0.key == key })
          ?? targets[key].map({ Self.row(for: $0, activity: activities[key], note: notes[key]) })
      else { continue }
      pinned.append(row)
      seen.insert(key)
    } // End of loop over the carried failures
    let liveKeys = Set(live.map(\.key))
    for key in actionKeys where !liveKeys.contains(key) && !seen.contains(key) {
      guard let activity = activities[key] else { continue }
      guard
        let row = all.first(where: { $0.key == key })
          ?? targets[key].map({ Self.row(for: $0, activity: activity, note: notes[key]) })
      else { continue }
      pinned.append(row)
      seen.insert(key)
    } // End of loop over the switcher's actions
    return pinned
  } // End of static func pinnedRows(all:live:carried:actionKeys:targets:activities:notes:)

  /// The row of a session the engine does not list, from its action's target: its name, its
  /// host's name, the target's counts, `activity` and `note`.
  static func row(for target: AttachTarget, activity: SessionActivity?, note: String?)
    -> SessionRow
  {
    SessionRow(
      key: target.key,
      name: target.session.name,
      hostName: target.host.displayName,
      detail: PopoverContent.countsText(
        windows: target.session.windowCount, clients: target.session.attachedClientCount),
      isStale: false,
      isOpenInITerm2Here: false,
      activity: activity,
      note: note,
      isSelected: false,
      clientCount: target.session.attachedClientCount)
  } // End of static func row(for:activity:note:)

  /// The muted line of `snapshot`'s host when its sessions are not listed: still checking
  /// (no attempt ended), or its last check failed; `nil` for a host that answered.
  static func hostLine(for snapshot: HostSnapshot) -> HostLine? {
    guard snapshot.freshness != .live else { return nil }
    let status = HostStatusLabel(snapshot)
    let text = status.text
    let lowered = text.prefix(1).lowercased() + text.dropFirst()
    return HostLine(
      id: snapshot.host.id, text: "\(snapshot.host.displayName): \(lowered)", tone: status.tone)
  }

  /// Selects `item` when it is listed, else the first item, and marks the selected row.
  private mutating func select(_ item: Item?) {
    let items = self.items
    let chosen = item.flatMap { items.contains($0) ? $0 : nil } ?? items.first
    selection = chosen
    for index in pinned.indices {
      pinned[index].isSelected = chosen == .session(pinned[index].key)
    }
    for index in rows.indices {
      rows[index].isSelected = chosen == .session(rows[index].key)
    }
    newSession?.isSelected = chosen == .newSession
  } // End of func select(_:)

  /// The item one row below (`down`) or above the selection, staying at the ends; `nil` when
  /// nothing is selectable.
  public func item(movingDown down: Bool) -> Item? {
    let items = self.items
    guard let selection, let position = items.firstIndex(of: selection) else {
      return items.first
    }
    return items[down ? min(position + 1, items.count - 1) : max(position - 1, 0)]
  }
}
