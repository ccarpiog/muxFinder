import Foundation
import Testing

@testable import MuxFinderCore
@testable import MuxFinderUI

/// `PopoverContent` and the strings it is made of: status labels, relative times, stale
/// marking, the "Open in iTerm2 here" badge, search filtering, empty states, notices, and the
/// preview fixtures. Pure values; no engine runs.
@Suite("Popover content")
struct PopoverContentTests {
  /// Shorthand.
  typealias Fixtures = PreviewFixtures

  /// The content of `fixture`.
  static func content(_ fixture: PreviewFixture) -> PopoverContent {
    PopoverContent(
      state: fixture.state, hostList: fixture.hostList, query: fixture.searchText,
      activities: fixture.activities, selection: fixture.selection, now: fixture.now)
  }

  /// The content of the overview hosts with `query`.
  static func overview(query: String = "") -> PopoverContent {
    var fixture = Fixtures.overview
    fixture.searchText = query
    return content(fixture)
  }

  // MARK: - Status mapping

  /// Each outcome maps to the plan's status, for SSH hosts and This Mac.
  @Test(arguments: [
    (Fixtures.snapshot(Fixtures.saturno, outcome: nil), HostStatusLabel.checking),
    (
      Fixtures.snapshot(
        Fixtures.saturno, outcome: .sessionsListed, sessions: Fixtures.saturnoSessions,
        lastSuccessAgo: 1), .reachable
    ),
    (Fixtures.snapshot(Fixtures.saturno, outcome: .sessionsListed, lastSuccessAgo: 1), .noSessions),
    (Fixtures.snapshot(Fixtures.saturno, outcome: .noServer, lastSuccessAgo: 1), .noSessions),
    (
      Fixtures.snapshot(
        Fixtures.neptuno, outcome: .sessionsListed, sessions: Fixtures.neptunoSessions,
        lastSuccessAgo: 1), .thisMac
    ),
    (Fixtures.snapshot(Fixtures.neptuno, outcome: .noServer, lastSuccessAgo: 1), .thisMac),
    (Fixtures.snapshot(Fixtures.sirio, outcome: .failed(.unreachable(.timeout))), .unreachable),
    (Fixtures.snapshot(Fixtures.sirio, outcome: .failed(.unreachable(.dnsFailure))), .unreachable),
    (Fixtures.snapshot(Fixtures.sirio, outcome: .failed(.unreachable(.refused))), .unreachable),
    (Fixtures.snapshot(Fixtures.sirio, outcome: .failed(.unreachable(.noRoute))), .unreachable),
    (Fixtures.snapshot(Fixtures.sirio, outcome: .failed(.authFailed)), .signInNeeded),
    (
      Fixtures.snapshot(Fixtures.sirio, outcome: .failed(.hostKeyProblem(.unknown))),
      .hostKeyProblem
    ),
    (
      Fixtures.snapshot(Fixtures.sirio, outcome: .failed(.hostKeyProblem(.changed))),
      .hostKeyProblem
    ),
    (Fixtures.snapshot(Fixtures.neptuno, outcome: .failed(.tmuxNotFound)), .tmuxNotFound),
    (Fixtures.snapshot(Fixtures.sirio, outcome: .failed(.probeError("Bad output."))), .checkFailed),
  ])
  func statusMapping(snapshot: HostSnapshot, expected: HostStatusLabel) {
    #expect(HostStatusLabel(snapshot) == expected)
  }

  /// A refresh in progress keeps the last outcome's label; only a host never checked is
  /// "Checking…".
  @Test func refreshingKeepsTheLastStatus() {
    let failing = Fixtures.snapshot(
      Fixtures.sirio, outcome: .failed(.unreachable(.timeout)), isRefreshing: true)
    #expect(HostStatusLabel(failing) == .unreachable)
    let first = Fixtures.snapshot(Fixtures.sirio, outcome: nil, isRefreshing: true)
    #expect(HostStatusLabel(first) == .checking)
    let section = PopoverContent.section(
      for: failing, attachmentCheck: .notChecked, activities: [:], selection: nil, now: .now)
    #expect(section.isRefreshing)
  }

  /// The status texts are exactly the plan's, and each has a tone.
  @Test func statusTexts() {
    let texts = HostStatusLabel.allCases.map(\.text)
    #expect(
      texts == [
        "Checking…", "Reachable", "This Mac", "No sessions", "Unreachable", "Sign-in needed",
        "Host key problem", "tmux not found", "Check failed",
      ])
    #expect(HostStatusLabel.reachable.tone == .good)
    #expect(HostStatusLabel.unreachable.tone == .muted)
    #expect(HostStatusLabel.signInNeeded.tone == .attention)
    #expect(HostStatusLabel.checking.tone == .neutral)
  } // End of func statusTexts()

  /// "Unreachable" alone has the muted tone (an offline Mac is routine, PLAN.md D22); every
  /// other status keeps its tone, and the statuses the user can act on stay "attention".
  @Test func statusTones() {
    let expected: [HostStatusLabel: HostStatusLabel.Tone] = [
      .checking: .neutral, .reachable: .good, .thisMac: .good, .noSessions: .neutral,
      .unreachable: .muted, .signInNeeded: .attention, .hostKeyProblem: .attention,
      .tmuxNotFound: .attention, .checkFailed: .attention,
    ]
    #expect(expected.count == HostStatusLabel.allCases.count)
    for status in HostStatusLabel.allCases {
      #expect(status.tone == expected[status], "\(status)")
    }
    #expect(HostStatusLabel.allCases.filter { $0.tone == .muted } == [.unreachable])
  } // End of func statusTones()

  /// Only an unreachable host's section reads muted; an attention host's does not.
  @Test func mutedSections() throws {
    let content = Self.overview()
    #expect(content.sections.filter(\.isMuted).map(\.name) == ["Sirio"])
    let problems = Self.content(Fixtures.hostProblems)
    #expect(problems.sections.allSatisfy { !$0.isMuted })
    let sirio = try #require(content.sections.last)
    #expect(sirio.problem != nil && sirio.rows.allSatisfy { $0.attachState == .stale })
  }

  /// Every failure has an explanation; successes have none; a probe error shows its message.
  @Test func problemTexts() {
    #expect(HostProblemText.explanation(for: .ok([])) == nil)
    #expect(HostProblemText.explanation(for: .noServer) == nil)
    let failures: [HostStatus] = [
      .unreachable(.timeout), .unreachable(.dnsFailure), .unreachable(.refused),
      .unreachable(.noRoute), .authFailed, .hostKeyProblem(.unknown), .hostKeyProblem(.changed),
      .tmuxNotFound,
    ]
    let texts = failures.compactMap(HostProblemText.explanation(for:))
    #expect(texts.count == failures.count)
    #expect(Set(texts).count == texts.count)
    #expect(texts.allSatisfy { $0.hasSuffix(".") })
    #expect(HostProblemText.explanation(for: .probeError("Bad output.")) == "Bad output.")
  } // End of func problemTexts()

  // MARK: - Relative times

  /// Whole minutes, hours and days, rounded down; under a minute or in the future is "just
  /// now".
  @Test(arguments: [
    (0.0, "just now"), (59.9, "just now"), (-30.0, "just now"), (60.0, "1 min ago"),
    (119.0, "1 min ago"), (120.0, "2 min ago"), (3_599.0, "59 min ago"), (3_600.0, "1 hr ago"),
    (7_199.0, "1 hr ago"), (86_399.0, "23 hr ago"), (86_400.0, "1 day ago"),
    (172_800.0, "2 days ago"), (864_000.0, "10 days ago"),
  ])
  func relativeTime(secondsAgo: TimeInterval, expected: String) {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(RelativeTime.phrase(for: now.addingTimeInterval(-secondsAgo), now: now) == expected)
  }

  /// The two sentences built on it.
  @Test func lastCheckedAndLastSeen() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(
      RelativeTime.lastChecked(now.addingTimeInterval(-120), now: now) == "Last checked 2 min ago")
    #expect(
      RelativeTime.lastSeen(now.addingTimeInterval(-180), now: now)
        == "Last seen 3 min ago · not live")
  }

  // MARK: - Rows, stale marking and badges

  /// Live rows show windows and clients; a client count of zero is "Detached".
  @Test func countsText() {
    #expect(PopoverContent.countsText(windows: 4, clients: 1) == "4 windows · 1 client")
    #expect(PopoverContent.countsText(windows: 1, clients: 0) == "1 window · Detached")
    #expect(PopoverContent.countsText(windows: 2, clients: 3) == "2 windows · 3 clients")
  }

  /// The sessions of an unreachable host are kept, marked stale with "Last seen … · not live",
  /// never with live counts; the host's caption is its last success.
  @Test func staleMarking() throws {
    let content = Self.overview()
    let sirio = try #require(content.sections.first { $0.name == "Sirio" })
    #expect(sirio.status == .unreachable)
    #expect(sirio.caption == "Last checked 3 min ago")
    #expect(sirio.problem == "The connection timed out.")
    #expect(sirio.emptyState == nil)
    #expect(sirio.rows.map(\.name) == ["thesis-draft", "photo-export"])
    #expect(sirio.rows.allSatisfy { $0.isStale })
    #expect(sirio.rows.allSatisfy { $0.detail == "Last seen 3 min ago · not live" })
    let saturno = try #require(content.sections.first { $0.name == "Saturno" })
    #expect(saturno.rows.allSatisfy { !$0.isStale })
    #expect(saturno.rows.map(\.detail) == ["4 windows · 1 client", "2 windows · Detached"])
    #expect(saturno.caption == "Last checked just now")
  } // End of func staleMarking()

  /// The badge comes only from the attachment index: a session with a client but no iTerm2
  /// connection here has none, and nothing in a row claims activity or idleness.
  @Test func badgeMapping() throws {
    let content = Self.overview()
    let rows = content.sections.flatMap(\.rows)
    let open = try #require(rows.first { $0.name == "build-farm" })
    #expect(open.isOpenInITerm2Here)
    #expect(open.accessibilityValue == "4 windows · 1 client, Open in iTerm2 here")
    let attachedElsewhere = try #require(rows.first { $0.name == "index-rebuild" })
    #expect(attachedElsewhere.detail == "3 windows · 2 clients")
    #expect(!attachedElsewhere.isOpenInITerm2Here)
    #expect(rows.filter(\.isOpenInITerm2Here).map(\.name) == ["build-farm"])
    let words = rows.flatMap { [$0.detail, $0.accessibilityValue] }.joined(separator: " ")
    for claim in ["idle", "active", "busy", "working"] {
      #expect(!words.lowercased().contains(claim))
    }
  } // End of func badgeMapping()

  /// Each row's attach state (its leading indicator) after an iTerm2 check that worked: open
  /// in iTerm2 here, attached elsewhere (clients, none here), detached, stale; only the first
  /// two read as attached. The badge comes first even for a stale row, since the attachment
  /// index is live.
  @Test func attachStateMapping() throws {
    let rows = Self.overview().sections.flatMap(\.rows)
    let states = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0.attachState) })
    #expect(
      states == [
        "build-farm": .here, "experiments": .detached, "notes": .detached,
        "index-rebuild": .attachedElsewhere, "thesis-draft": .stale, "photo-export": .stale,
      ])
    #expect(rows.map(\.clientCount) == [1, 0, 0, 2, 1, 0])
    #expect(rows.filter(\.isAttached).map(\.name) == ["build-farm", "index-rebuild"])
    let openHere = Fixtures.session(
      "draft", id: 50, on: Fixtures.sirio, windows: 1, clients: 1, openHere: true)
    let staleOpenHere = Fixtures.snapshot(
      Fixtures.sirio, outcome: .failed(.unreachable(.timeout)), sessions: [openHere],
      lastSuccessAgo: 60, lastAttemptAgo: 5)
    let section = PopoverContent.section(
      for: staleOpenHere, attachmentCheck: .checked(at: Fixtures.now, counts: .init(mapped: 1)),
      activities: [:], selection: nil, now: Fixtures.now)
    let row = try #require(section.rows.first)
    #expect(row.isStale && row.isOpenInITerm2Here)
    #expect(row.attachState == .here)
  } // End of func attachStateMapping()

  /// A row with clients is "attached elsewhere" only when this Mac's iTerm2 check says where
  /// (it worked, or found iTerm2 not running). A failed check, or one not run yet, leaves the
  /// location unknown on every host, This Mac and SSH ones alike (the one check covers them
  /// all); nothing in a row's text says "elsewhere" either way. Without a working check no
  /// session carries an attachment (the engine clears them), as here; detached and stale rows
  /// read the same whatever the check.
  @Test(arguments: [
    (AttachmentCheck.checked(at: Fixtures.now, counts: .init(mapped: 1)), true),
    (AttachmentCheck.iTermNotRunning(at: Fixtures.now), true),
    (AttachmentCheck.failed(at: Fixtures.now, error: .apiDisabled), false),
    (AttachmentCheck.failed(at: Fixtures.now, error: nil), false),
    (AttachmentCheck.notChecked, false),
  ])
  func attachStateFollowsTheAttachmentCheck(check: AttachmentCheck, knowsWhere: Bool) {
    #expect(PopoverContent.knowsWhatIsOpenHere(check) == knowsWhere)
    let isChecked = if case .checked = check { true } else { false }
    let hosts = Fixtures.overviewHosts.map { snapshot in
      var snapshot = snapshot
      if !isChecked {
        snapshot.sessions = snapshot.sessions.map {
          HostSnapshot.Session(discovered: $0.discovered)
        }
      }
      return snapshot
    }
    let content = PopoverContent(
      state: Fixtures.state(hosts, attachmentCheck: check), hostList: .saved, query: "",
      activities: [:], selection: nil, now: Fixtures.now)
    let rows = content.sections.flatMap(\.rows)
    let states = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0.attachState) })
    let attached: SessionRow.AttachState =
      knowsWhere ? .attachedElsewhere : .attachedUnknownLocation
    #expect(
      states == [
        "build-farm": isChecked ? .here : attached, "experiments": .detached, "notes": .detached,
        "index-rebuild": attached, "thesis-draft": .stale, "photo-export": .stale,
      ])
    #expect(rows.filter(\.isAttached).map(\.name) == ["build-farm", "index-rebuild"])
    // "build-farm" is on Saturno (SSH), "index-rebuild" on Neptuno (This Mac).
    #expect(Fixtures.saturno.mode == .ssh && Fixtures.neptuno.mode == .local)
    for row in rows {
      #expect(!row.detail.lowercased().contains("elsewhere"), "\(row.name)")
      #expect(!row.accessibilityValue.lowercased().contains("elsewhere"), "\(row.name)")
    }
  } // End of func attachStateFollowsTheAttachmentCheck(check:knowsWhere:)

  /// A failed iTerm2 check shows no badge, a notice that the badges are unknown, and no row
  /// with clients as attached elsewhere: their location is unknown.
  @Test func failedAttachmentCheck() {
    let content = Self.content(Fixtures.iTermCheckFailed)
    let rows = content.sections.flatMap(\.rows)
    #expect(rows.allSatisfy { !$0.isOpenInITerm2Here })
    #expect(rows.contains { $0.clientCount > 0 })
    for row in rows where row.clientCount > 0 {
      #expect(row.attachState == .attachedUnknownLocation, "\(row.name)")
      #expect(row.isAttached)
    }
    #expect(!rows.contains { $0.attachState == .attachedElsewhere })
    #expect(content.notices.map(\.kind) == [.attachmentCheck])
    #expect(content.notices[0].text.contains("could not check which sessions are open in iTerm2"))
    #expect(content.notices[0].text.contains("Enable Python API"))
  } // End of func failedAttachmentCheck()

  /// Rows and headers carry accessibility labels and values.
  @Test func accessibility() throws {
    let content = Self.overview()
    let saturno = try #require(content.sections.first)
    #expect(saturno.accessibilityLabel == "Saturno")
    #expect(saturno.accessibilityValue == "Reachable, Last checked just now")
    let row = try #require(saturno.rows.last)
    #expect(row.accessibilityLabel == "experiments on Saturno")
    #expect(row.accessibilityValue == "2 windows · Detached")
    let sirio = try #require(content.sections.last)
    #expect(
      sirio.accessibilityValue
        == "Unreachable, Last checked 3 min ago, The connection timed out.")
    let progress = Self.content(Fixtures.progress)
    let opening = try #require(progress.sections.first?.rows.first)
    #expect(opening.accessibilityValue == "2 windows · Detached, Opening…")
  } // End of func accessibility()

  /// The keyboard selection marks exactly its row.
  @Test func selectionMarksOneRow() {
    let rows = Self.overview().sections.flatMap(\.rows)
    #expect(rows.filter(\.isSelected).map(\.name) == ["experiments"])
  }

  // MARK: - Search

  /// A session name match keeps only matching sessions; hosts without one disappear.
  @Test func searchFiltersSessionNames() {
    let content = Self.overview(query: "ex")
    #expect(content.sections.map(\.name) == ["Saturno", "Neptuno", "Sirio"])
    #expect(
      content.sections.map { $0.rows.map(\.name) } == [
        ["experiments"], ["index-rebuild"], ["photo-export"],
      ])
    let farm = Self.overview(query: "farm")
    #expect(farm.sections.map(\.name) == ["Saturno"])
    #expect(farm.selectableKeys == [Fixtures.saturnoSessions[0].key])
  } // End of func searchFiltersSessionNames()

  /// A host name match keeps all of its sessions.
  @Test func searchMatchesHostNames() {
    let content = Self.overview(query: "sirio")
    #expect(content.sections.map(\.name) == ["Sirio"])
    #expect(content.sections[0].rows.map(\.name) == ["thesis-draft", "photo-export"])
  }

  /// Matching ignores case, diacritics and surrounding spaces; an empty query shows all.
  @Test func searchIgnoresCaseDiacriticsAndSpaces() {
    #expect(Self.overview(query: "  NOTES ").selectableKeys == [Fixtures.neptunoSessions[0].key])
    #expect(Self.overview(query: "índex").selectableKeys == [Fixtures.neptunoSessions[1].key])
    #expect(Self.overview(query: "SATÚRNO").sections.map(\.name) == ["Saturno"])
    #expect(Self.overview(query: "   ").selectableKeys.count == 6)
    #expect(Self.overview().placeholder == nil)
  }

  /// No match replaces the list with a placeholder naming the query.
  @Test func searchWithoutMatches() {
    let content = Self.overview(query: "zebra")
    #expect(content.sections.isEmpty)
    #expect(content.selectableKeys.isEmpty)
    #expect(content.placeholder == .noMatches(query: "zebra"))
    #expect(content.placeholder?.message == "No host or session name contains “zebra”.")
  }

  /// A host matched by name keeps its empty state; the same host is left out when only
  /// session names are searched.
  @Test func searchAndEmptyHosts() {
    var fixture = Fixtures.checkingAndEmpty
    fixture.searchText = "nept"
    let byName = Self.content(fixture)
    #expect(byName.sections.map(\.name) == ["Neptuno"])
    #expect(byName.sections[0].emptyState == PopoverContent.emptyHostText)
    fixture.searchText = "work"
    #expect(Self.content(fixture).placeholder == .noMatches(query: "work"))
  }

  // MARK: - Empty states and notices

  /// A host that answered with no sessions shows the empty state; one never checked shows
  /// "Checking…" with no caption; one never reached says so.
  @Test func hostEmptyStates() throws {
    let content = Self.content(Fixtures.checkingAndEmpty)
    let checking = try #require(content.sections.first { $0.name == "Saturno" })
    #expect(checking.status == .checking)
    #expect(checking.caption == nil)
    #expect(checking.emptyState == nil)
    let thisMac = try #require(content.sections.first { $0.name == "Neptuno" })
    #expect(thisMac.status == .thisMac)
    #expect(thisMac.emptyState == "No tmux sessions here. Use New session to start one.")
    let empty = try #require(content.sections.first { $0.name == "Sirio" })
    #expect(empty.status == .noSessions)
    #expect(empty.caption == "Last checked 2 hr ago")
    #expect(empty.emptyState != nil)
    let problems = Self.content(Fixtures.hostProblems)
    #expect(problems.sections[0].caption == "Not reached yet")
    #expect(problems.sections[0].emptyState == nil)
    #expect(problems.sections.allSatisfy { $0.problem != nil })
  } // End of func hostEmptyStates()

  /// No state yet is "Loading hosts…"; no enabled host is "No hosts turned on".
  @Test func globalPlaceholders() {
    #expect(Self.content(Fixtures.loading).placeholder == .loading)
    let noHosts = Self.content(Fixtures.noHosts)
    #expect(noHosts.placeholder == .noHostsEnabled)
    #expect(noHosts.placeholder?.title == "No hosts turned on")
    #expect(noHosts.notices.isEmpty)
    var searching = Fixtures.noHosts
    searching.searchText = "x"
    #expect(Self.content(searching).placeholder == .noHostsEnabled)
  }

  /// An unusable host list or folder is reported above the list.
  @Test func hostListNotices() {
    let invalid = Self.content(Fixtures.invalidHostList)
    #expect(invalid.notices.map(\.kind) == [.hostList])
    #expect(invalid.notices[0].text.hasSuffix("The host list file isn't valid JSON."))
    let unreadable = PopoverContent(
      state: nil, hostList: .unreadable(message: "Gone."), query: "", activities: [:],
      selection: nil, now: .now)
    #expect(
      unreadable.notices.map(\.text) == ["muxFinder could not read its settings folder. Gone."])
    #expect(Self.content(Fixtures.overview).notices.isEmpty)
  } // End of func hostListNotices()

  // MARK: - Activities

  /// Attach states map to the row texts; "Confirmed" and the focus are results, not progress.
  @Test func activityMapping() {
    #expect(SessionActivity(.requested).text == "Opening…")
    #expect(SessionActivity(.requested, movingHere: true).text == "Moving here…")
    #expect(SessionActivity(.launched(sessionID: "s")).text == "Waiting for iTerm2…")
    #expect(
      SessionActivity(.stillWaiting(sessionID: "s")).text
        == "Still connecting — check the iTerm2 tab")
    let confirmed = SessionActivity(.confirmed(connectionID: "c"))
    #expect(confirmed.text == "Confirmed — open in iTerm2 on this Mac")
    #expect(confirmed.isDone && !confirmed.isInProgress)
    #expect(SessionActivity(.focused(connectionID: "c")) == .focused)
    #expect(SessionActivity.detached.text.contains("keeps running"))
    let failed = SessionActivity(.failed(.sessionGone))
    #expect(failed.text == AttachFailure.sessionGone.message)
    #expect(failed.problem?.recoveries == [.refresh])
    #expect(!failed.isInProgress && !failed.isDone)
    #expect(SessionActivity.opening.isInProgress)
    #expect(SessionActivity.detaching.isInProgress)
  } // End of func activityMapping()

  // MARK: - Fixtures

  /// Together the fixtures show every status, progress text, placeholder, notice, a badge, a
  /// stale session, a selection (one on a row with the badge), every attach state, an
  /// unreachable host next to an attention one, and an empty host: the preview window covers
  /// every state.
  @Test func fixturesCoverEveryState() {
    let contents = Fixtures.all.map(Self.content)
    let statuses = Set(contents.flatMap { $0.sections.map(\.status) })
    #expect(statuses == Set(HostStatusLabel.allCases))
    let activities = Set(
      contents.flatMap { $0.sections.flatMap { $0.rows.compactMap(\.activity) } })
    #expect(activities.contains(.opening))
    #expect(activities.contains(.waitingForITerm2))
    #expect(activities.contains(.stillConnecting(launchTabID: "fixture")))
    #expect(activities.contains { !$0.isInProgress })
    let placeholders = Set(contents.compactMap(\.placeholder))
    #expect(placeholders.contains(.loading))
    #expect(placeholders.contains(.noHostsEnabled))
    #expect(placeholders.contains { if case .noMatches = $0 { true } else { false } })
    #expect(Set(contents.flatMap { $0.notices.map(\.kind) }) == [.hostList, .attachmentCheck])
    let rows = contents.flatMap { $0.sections.flatMap(\.rows) }
    #expect(rows.contains { $0.isOpenInITerm2Here })
    #expect(rows.contains { $0.isStale })
    #expect(rows.contains { $0.isSelected })
    #expect(rows.contains { $0.isSelected && $0.isOpenInITerm2Here })
    #expect(Set(rows.map(\.attachState)) == Set(SessionRow.AttachState.allCases))
    let mutedNextToAttention = contents.contains { content in
      zip(content.sections, content.sections.dropFirst()).contains { pair in
        Set([pair.0.status.tone, pair.1.status.tone]) == [.muted, .attention]
      }
    }
    #expect(mutedNextToAttention)
    #expect(contents.contains { $0.sections.contains { $0.emptyState != nil } })
    #expect(Set(Fixtures.all.map(\.id)).count == Fixtures.all.count)
  } // End of func fixturesCoverEveryState()

  /// The fixtures hold only synthetic data: invented destinations, a fake socket path.
  @Test func fixturesAreSynthetic() {
    let hosts = Fixtures.all.compactMap(\.state).flatMap(\.hosts).map(\.host)
    #expect(hosts.filter { $0.mode == .ssh }.allSatisfy { $0.sshDestination.hasSuffix(".example") })
    let sessions = Fixtures.all.compactMap(\.state).flatMap(\.sessions)
    #expect(sessions.allSatisfy { $0.key.server.socketPath == "/tmp/tmux-fixture/default" })
  }
}
