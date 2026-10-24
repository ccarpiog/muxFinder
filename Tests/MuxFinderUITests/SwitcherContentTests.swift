import Foundation
import Testing

@testable import MuxFinderCore
@testable import MuxFinderUI

/// `SwitcherContent` (PLAN.md D32, Phase I-3b), a pure value: live sessions only, in the
/// popover's order, the popover's filter, the New session row's text and name, the selection
/// kept across updates, the empty, no-hosts and loading states, the host lines, and the pinned
/// rows. Synthetic sessions only; nothing runs.
@Suite("Session switcher content")
struct SwitcherContentTests {
  /// Shorthand.
  typealias Fixtures = PreviewFixtures

  /// This Mac's sessions.
  static let neptuno = [
    Fixtures.session("notes", id: 1, on: Fixtures.neptuno, windows: 2, clients: 1, openHere: true),
    Fixtures.session("café-log", id: 2, on: Fixtures.neptuno, windows: 1),
  ]
  /// Saturno's sessions.
  static let saturno = [
    Fixtures.session("build-farm", id: 3, on: Fixtures.saturno, windows: 4, clients: 1),
    Fixtures.session("experiments", id: 4, on: Fixtures.saturno, windows: 2),
  ]
  /// Sirio's sessions from its last success.
  static let sirio = [Fixtures.session("thesis-draft", id: 5, on: Fixtures.sirio, windows: 1)]

  /// This Mac and Saturno answered; Sirio is unreachable with stale sessions.
  static let state = Fixtures.state([
    Fixtures.snapshot(
      Fixtures.neptuno, outcome: .sessionsListed, sessions: neptuno, lastSuccessAgo: 5),
    Fixtures.snapshot(
      Fixtures.saturno, outcome: .sessionsListed, sessions: saturno, lastSuccessAgo: 5),
    Fixtures.snapshot(
      Fixtures.sirio, outcome: .failed(.unreachable(.timeout)), sessions: sirio,
      lastSuccessAgo: 600, lastAttemptAgo: 10),
  ])

  /// The content for `state` with `query`, `selection` and the rest as given.
  static func content(
    _ state: RefreshState? = state,
    query: String = "",
    selection: SwitcherContent.Item? = nil,
    activities: [SessionKey: SessionActivity] = [:],
    carried: [SessionKey] = [],
    actionKeys: [SessionKey] = [],
    targets: [SessionKey: AttachTarget] = [:]
  ) -> SwitcherContent {
    SwitcherContent(
      state: state, hostList: .saved, query: query, selection: selection,
      activities: activities, now: Fixtures.now, carried: carried, actionKeys: actionKeys,
      targets: targets)
  } // End of static func content(_:query:selection:activities:carried:actionKeys:targets:)

  /// Stale sessions are left out (Sirio lists nothing), the rest keep the popover's order (host
  /// order, then session order) and its rows (state, detail, badge); New session comes last.
  @Test func liveSessionsInThePopoversOrder() {
    let content = Self.content()
    #expect(content.rows.map(\.name) == ["notes", "café-log", "build-farm", "experiments"])
    #expect(!content.rows.contains { $0.isStale })
    #expect(content.rows[0].attachState == .here && content.rows[0].isOpenInITerm2Here)
    #expect(content.rows[2].detail == "4 windows · 1 client")
    #expect(content.rows[2].accessibilityLabel == "build-farm on Saturno")
    #expect(content.items.last == .newSession && content.items.count == 5)
    #expect(content.pinned.isEmpty && content.emptyText == nil && content.placeholder == nil)
  }

  /// The popover's filter over host and session names: a host name keeps all its sessions;
  /// otherwise matching session names only; case, diacritics and surrounding spaces ignored.
  @Test func filterUsesThePopoversRule() {
    #expect(Self.content(query: "satur").rows.map(\.name) == ["build-farm", "experiments"])
    #expect(Self.content(query: "EXP").rows.map(\.name) == ["experiments"])
    #expect(Self.content(query: "  cafe ").rows.map(\.name) == ["café-log"])
    #expect(Self.content(query: "thesis").rows.isEmpty)
    #expect(Self.content(query: "e").rows.map(\.name) == ["notes", "café-log", "experiments"])
  }

  /// The New session row: "New session…" without a filter; the filter's valid name (trimmed)
  /// when no live session has exactly that name; none for an existing name, an invalid one, or
  /// an empty one; a stale session's name does not count.
  @Test func newSessionRowTextAndPrefill() {
    #expect(Self.content().newSession?.title == "New session…")
    #expect(Self.content().newSession?.prefill == nil)
    let deploy = Self.content(query: "  deploy-docs ").newSession
    #expect(deploy?.prefill == "deploy-docs")
    #expect(deploy?.title == "New session “deploy-docs”…")
    #expect(deploy?.accessibilityLabel == "New session “deploy-docs”…")
    #expect(Self.content(query: "notes").newSession?.prefill == nil)
    #expect(Self.content(query: "notes").newSession?.title == "New session…")
    #expect(Self.content(query: "note").newSession?.prefill == "note")
    #expect(Self.content(query: "logs:old").newSession?.prefill == nil)
    #expect(Self.content(query: "   ").newSession?.prefill == nil)
    #expect(Self.content(query: "thesis-draft").newSession?.prefill == "thesis-draft")
  } // End of func newSessionRowTextAndPrefill()

  /// The selection stays on the same session when the engine's state changes (a session added
  /// above it, counts changed); a session no longer listed, or none, selects the first row.
  @Test func selectionKeptAcrossUpdates() {
    let key = Self.saturno[1].key
    let before = Self.content(selection: .session(key))
    #expect(before.selection == .session(key))
    #expect(before.rows.filter(\.isSelected).map(\.key) == [key])
    var changed = Self.saturno
    changed.insert(Fixtures.session("aaa-new", id: 9, on: Fixtures.saturno, windows: 1), at: 0)
    changed[2] = Fixtures.session(
      "experiments", id: 4, on: Fixtures.saturno, windows: 7, clients: 2)
    let updated = Self.content(
      Fixtures.state([
        Fixtures.snapshot(
          Fixtures.neptuno, outcome: .sessionsListed, sessions: Self.neptuno, lastSuccessAgo: 1),
        Fixtures.snapshot(
          Fixtures.saturno, outcome: .sessionsListed, sessions: changed, lastSuccessAgo: 1),
      ]),
      selection: .session(key))
    #expect(updated.selection == .session(key))
    #expect(updated.rows.first { $0.isSelected }?.detail == "7 windows · 2 clients")
    let gone = Self.content(
      Fixtures.state([
        Fixtures.snapshot(
          Fixtures.neptuno, outcome: .sessionsListed, sessions: Self.neptuno, lastSuccessAgo: 1)
      ]),
      selection: .session(key))
    #expect(gone.selection == .session(Self.neptuno[0].key))
    #expect(Self.content().selection == .session(Self.neptuno[0].key))
    #expect(Self.content(selection: .newSession).newSession?.isSelected == true)
  } // End of func selectionKeptAcrossUpdates()

  /// ↑/↓ move through the items without wrapping.
  @Test func movingTheSelectionStopsAtTheEnds() {
    let first = Self.content()
    #expect(first.item(movingDown: false) == .session(Self.neptuno[0].key))
    #expect(first.item(movingDown: true) == .session(Self.neptuno[1].key))
    let last = Self.content(selection: .newSession)
    #expect(last.item(movingDown: true) == .newSession)
    #expect(last.item(movingDown: false) == .session(Self.saturno[1].key))
  }

  /// No live session: "No live sessions." and only New session, selected; a filter that matches
  /// nothing says so.
  @Test func emptyState() {
    let empty = Self.content(
      Fixtures.state([Fixtures.snapshot(Fixtures.neptuno, outcome: .noServer, lastSuccessAgo: 1)]))
    #expect(empty.rows.isEmpty && empty.emptyText == SwitcherContent.noLiveSessionsText)
    #expect(empty.items == [.newSession] && empty.selection == .newSession)
    #expect(empty.hostLines.isEmpty)
    let noMatch = Self.content(query: " zebra ")
    #expect(noMatch.emptyText == "No session matches “zebra”.")
    #expect(noMatch.selection == .newSession && noMatch.newSession?.prefill == "zebra")
  }

  /// No host turned on gives the popover's placeholder, no rows and no New session row; the
  /// host list still loading gives the loading placeholder.
  @Test func noHostsAndLoading() {
    let none = Self.content(Fixtures.state([], attachmentCheck: .notChecked))
    #expect(none.placeholder == .noHostsEnabled)
    #expect(none.rows.isEmpty && none.newSession == nil && none.items.isEmpty)
    #expect(none.selection == nil && none.hostLines.isEmpty && none.emptyText == nil)
    let loading = Self.content(nil)
    #expect(loading.placeholder == .loading && loading.items.isEmpty)
  }

  /// Muted lines for hosts still checking or whose last check failed, in host order, with the
  /// status's tone (never red); none for a host that answered.
  @Test func hostLines() {
    let content = Self.content(
      Fixtures.state([
        Fixtures.snapshot(Fixtures.saturno, outcome: nil, isRefreshing: true),
        Fixtures.snapshot(Fixtures.neptuno, outcome: .sessionsListed, lastSuccessAgo: 1),
        Fixtures.snapshot(
          Fixtures.sirio, outcome: .failed(.unreachable(.timeout)), lastAttemptAgo: 1),
      ]))
    #expect(content.hostLines.map(\.text) == ["Saturno: checking…", "Sirio: unreachable"])
    #expect(content.hostLines.map(\.tone) == [.neutral, .muted])
    let signIn = Self.content(
      Fixtures.state([Fixtures.snapshot(Fixtures.saturno, outcome: .failed(.authFailed))]))
    #expect(signIn.hostLines.map(\.text) == ["Saturno: sign-in needed"])
    let tmux = Self.content(
      Fixtures.state([Fixtures.snapshot(Fixtures.saturno, outcome: .failed(.tmuxNotFound))]))
    #expect(tmux.hostLines.map(\.text) == ["Saturno: tmux not found"])
    #expect(Self.content().hostLines.map(\.text) == ["Sirio: unreachable"])
  } // End of func hostLines()

  /// Pinned rows: a carried failure comes first and is not repeated below (one no longer
  /// failed is not pinned); an action's session the engine does not list is pinned from its
  /// target with its activity; a listed one stays in place.
  @Test func pinnedRows() {
    let failed = Self.saturno[1].key
    let problem = SessionActivity.failed(.attach(.timedOut))
    let carried = Self.content(activities: [failed: problem], carried: [failed])
    #expect(carried.pinned.map(\.key) == [failed])
    #expect(!carried.rows.contains { $0.key == failed })
    #expect(carried.items.first == .session(failed) && carried.selection == .session(failed))
    #expect(Self.content(carried: [failed]).pinned.isEmpty)
    let stale = Self.sirio[0].key
    let staleCarried = Self.content(activities: [stale: problem], carried: [stale])
    #expect(staleCarried.pinned.map(\.name) == ["thesis-draft"])
    let created = Fixtures.session("fresh", id: 30, on: Fixtures.neptuno, windows: 1).discovered
    let target = AttachTarget(host: Fixtures.neptuno, session: created)
    let pending = Self.content(
      activities: [created.key: .opening, Self.saturno[0].key: .opening],
      actionKeys: [created.key, Self.saturno[0].key], targets: [created.key: target])
    #expect(pending.pinned.map(\.name) == ["fresh"])
    #expect(pending.pinned.first?.hostName == "Neptuno")
    #expect(pending.pinned.first?.activity == .opening)
    #expect(pending.rows.contains { $0.key == Self.saturno[0].key && $0.activity == .opening })
    #expect(
      Self.content(query: "zzz", activities: [failed: problem], carried: [failed]).pinned.isEmpty)
  } // End of func pinnedRows()
}
