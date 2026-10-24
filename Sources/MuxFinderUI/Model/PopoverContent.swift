import Foundation
import MuxFinderCore

/// How the host list loaded (PLAN.md D19), as far as the popover cares.
public enum HostListStatus: Sendable, Hashable {
  /// `hosts.json` was read.
  case saved
  /// There is no `hosts.json` yet: the onboarding examples, all turned off.
  case notSavedYet
  /// `hosts.json` could not be used and was left as it is; the examples are shown instead.
  case invalid(HostFileProblem)
  /// muxFinder's folder could not be read; `message` says why.
  case unreadable(message: String)
}

/// One session row of the popover.
public struct SessionRow: Sendable, Hashable, Identifiable {
  /// The badge text for a session that iTerm2 on this Mac shows (PLAN.md D16).
  public static let openHereBadge = "Open in iTerm2 here"

  /// Where the session is attached, as the row's leading indicator shows it (PLAN.md D22).
  /// It says only whether and where tmux clients are attached, never whether anything runs or
  /// idles in the session; the row's text says the same, so the indicator is never the only
  /// signal.
  public enum AttachState: Sendable, Hashable, CaseIterable {
    /// An iTerm2 tmux connection on this Mac shows the session (the attachment index only).
    case here
    /// At least one tmux client is attached, and this Mac's last iTerm2 check worked (or found
    /// iTerm2 not running) and shows none of them in this Mac's iTerm2 ("1 client").
    case attachedElsewhere
    /// At least one tmux client is attached, and where is unknown: this Mac's iTerm2 check
    /// failed or has not run, so it may be this Mac's iTerm2 ("1 client", and the notice).
    case attachedUnknownLocation
    /// No tmux client is attached ("Detached").
    case detached
    /// The row comes from the host's last success and is not live ("Last seen … · not live").
    case stale
  }

  /// The session's identity (host, server, session id).
  public var key: SessionKey
  /// The session name (display text only).
  public var name: String
  /// The host's display name.
  public var hostName: String
  /// "4 windows · 1 client", "2 windows · Detached", or for a stale session
  /// "Last seen 3 min ago · not live".
  public var detail: String
  /// Whether the session comes from the host's last success and is not live.
  public var isStale: Bool
  /// Whether an iTerm2 tmux connection on this Mac shows the session, from `AttachmentIndex`
  /// only. A tmux client count never sets it.
  public var isOpenInITerm2Here: Bool
  /// Work in progress on the session, or how its last action ended.
  public var activity: SessionActivity?
  /// A note under the activity (why "Show tab" did nothing).
  public var note: String?
  /// Whether the keyboard selection is on this row.
  public var isSelected: Bool
  /// Whether "Detach from this Mac" is offered: the session has an attachment in this Mac's
  /// iTerm2, by the attachment index or because muxFinder made or found it (PLAN.md D25).
  public var offersDetach = false
  /// How many tmux clients the host's listing showed attached, anywhere (for a stale row, the
  /// last success's count).
  public var clientCount = 0
  /// Whether this Mac's last iTerm2 check says which sessions are open in iTerm2 here (it
  /// worked, or iTerm2 was not running; `PopoverContent.knowsWhatIsOpenHere(_:)`). The one
  /// check covers every host, SSH ones too. Without it a client count never says where.
  public var knowsWhatIsOpenHere = false

  /// Whether "Move here…" is offered: not while this Mac's iTerm2 shows the session already
  /// (the move would refuse, PLAN.md D21).
  public var offersMoveHere: Bool { !isOpenInITerm2Here }

  /// The leading indicator's state. "Open in iTerm2 here" comes first, since the attachment
  /// index is live even when the host's listing is stale; then a stale row; then the live
  /// client count, "elsewhere" only when the iTerm2 check says none of them is here.
  public var attachState: AttachState {
    if isOpenInITerm2Here { return .here }
    if isStale { return .stale }
    guard clientCount > 0 else { return .detached }
    return knowsWhatIsOpenHere ? .attachedElsewhere : .attachedUnknownLocation
  }

  /// Whether the row reads as attached (its name stronger than a detached one's).
  public var isAttached: Bool {
    switch attachState {
    case .here, .attachedElsewhere, .attachedUnknownLocation: return true
    case .detached, .stale: return false
    }
  }

  /// `Identifiable` conformance: the session key.
  public var id: SessionKey { key }

  /// The VoiceOver label: the session and its host.
  public var accessibilityLabel: String { "\(name) on \(hostName)" }

  /// The VoiceOver value: the counts or staleness, the badge and the activity.
  public var accessibilityValue: String {
    var parts = [detail]
    if isOpenInITerm2Here { parts.append(Self.openHereBadge) }
    if let activity { parts.append(activity.text) }
    return parts.joined(separator: ", ")
  }
}

/// One host's group in the popover.
public struct HostSection: Sendable, Hashable, Identifiable {
  /// The host's id.
  public var id: UUID
  /// The host's display name.
  public var name: String
  /// The header's status label.
  public var status: HostStatusLabel
  /// Whether an attempt runs or waits for a slot (a spinner beside the status).
  public var isRefreshing: Bool
  /// "Last checked 2 min ago" (the last success), "Not reached yet" (attempts, no success),
  /// or `nil` before the first attempt.
  public var caption: String?
  /// Why the last attempt failed; shown with "Retry".
  public var problem: String?
  /// The text shown when the host answered with no sessions.
  public var emptyState: String?
  /// The sessions shown (after search filtering).
  public var rows: [SessionRow]
  /// Whether "Set up SSH in iTerm2 first" is offered next to the problem (a sign-in needed or
  /// a host key problem on an SSH host with a valid destination, PLAN.md D24).
  public var offersSSHSetup = false
  /// That action's line, while it has one.
  public var sshSetup: SSHSetupState?

  /// Whether the section reads muted (an unreachable host, PLAN.md D22): its name, caption
  /// and status in secondary colors, a hollow status dot, a neutral icon on the problem line.
  public var isMuted: Bool { status.tone == .muted }

  /// The VoiceOver label: the host name.
  public var accessibilityLabel: String { name }

  /// The VoiceOver value: status, caption, refreshing and the problem.
  public var accessibilityValue: String {
    var parts = [status.text]
    if let caption { parts.append(caption) }
    if isRefreshing { parts.append("Refreshing") }
    if let problem { parts.append(problem) }
    return parts.joined(separator: ", ")
  }
}

/// Everything the popover shows, computed from the refresh engine's state, the search text,
/// the per-session activities and the selection. A pure value, so every rule here is tested
/// without SwiftUI.
public struct PopoverContent: Sendable, Hashable {
  /// What replaces the host list when there is nothing to list.
  public enum Placeholder: Sendable, Hashable {
    /// The host list is still loading.
    case loading
    /// No host is turned on (the onboarding examples start turned off).
    case noHostsEnabled
    /// The search matched no host and no session.
    case noMatches(query: String)

    /// The title line.
    public var title: String {
      switch self {
      case .loading: return "Loading hosts…"
      case .noHostsEnabled: return "No hosts turned on"
      case .noMatches: return "No matches"
      }
    }

    /// The explanation under the title, if any.
    public var message: String? {
      switch self {
      case .loading:
        return nil
      case .noHostsEnabled:
        return "Set up your Macs in Settings to see their tmux sessions here. muxFinder lists "
          + "each Mac's default tmux server."
      case .noMatches(let query):
        return "No host or session name contains “\(query)”."
      }
    } // End of var message
  } // End of enum Placeholder

  /// A problem shown above the host list.
  public struct Notice: Sendable, Hashable, Identifiable {
    /// Which problem.
    public enum Kind: Sendable, Hashable {
      /// The host list could not be used or read.
      case hostList
      /// The check of which sessions are open in iTerm2 failed: the badges are unknown.
      case attachmentCheck
    }

    /// Which problem.
    public var kind: Kind
    /// The explanation.
    public var text: String
    /// The button that helps fix it, if any (PLAN.md D23).
    public var fixIt: FixIt?

    /// `Identifiable` conformance: the kind (at most one notice of each).
    public var id: Kind { kind }
  }

  /// The host groups, in host-list order, after search filtering.
  public var sections: [HostSection]
  /// What replaces the host list, if anything.
  public var placeholder: Placeholder?
  /// Problems shown above the host list.
  public var notices: [Notice]
  /// Sessions that vanished or changed between the listing and an action, newest first.
  public var banners: [SessionBanner]

  /// The rows the keyboard moves through, top to bottom.
  public var selectableKeys: [SessionKey] { sections.flatMap { $0.rows.map(\.key) } }

  /// The content for `state` (`nil` while loading) with the search `query`, the sessions'
  /// `activities` and `notes`, the keyboard `selection`, relative times seen at `now`, the
  /// hosts' "Set up SSH in iTerm2…" lines (`sshSetupStates`, by host id), the `banners`, and
  /// the sessions muxFinder attached or found in this Mac's iTerm2 (`attachedHere`).
  ///
  /// Search: a host whose name contains the query shows all its sessions; any other host
  /// shows only the sessions whose names contain it, and is left out when none does. Matching
  /// ignores case and diacritics and surrounding spaces; an empty query shows everything.
  public init(
    state: RefreshState?,
    hostList: HostListStatus?,
    query: String,
    activities: [SessionKey: SessionActivity],
    selection: SessionKey?,
    now: Date,
    sshSetupStates: [UUID: SSHSetupState] = [:],
    notes: [SessionKey: String] = [:],
    banners: [SessionBanner] = [],
    attachedHere: Set<SessionKey> = []
  ) {
    notices = Self.notices(hostList: hostList, attachmentCheck: state?.attachmentCheck)
    self.banners = banners
    guard let state else {
      sections = []
      placeholder = .loading
      return
    }
    guard !state.hosts.isEmpty else {
      sections = []
      placeholder = .noHostsEnabled
      return
    }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    var built: [HostSection] = []
    for snapshot in state.hosts {
      var section = Self.section(
        for: snapshot, attachmentCheck: state.attachmentCheck, activities: activities,
        selection: selection, now: now)
      for index in section.rows.indices {
        let key = section.rows[index].key
        section.rows[index].note = notes[key]
        section.rows[index].offersDetach =
          section.rows[index].isOpenInITerm2Here || attachedHere.contains(key)
      }
      if section.offersSSHSetup { section.sshSetup = sshSetupStates[snapshot.host.id] }
      if !trimmed.isEmpty, !Self.matches(snapshot.host.displayName, query: trimmed) {
        section.rows = section.rows.filter { Self.matches($0.name, query: trimmed) }
        guard !section.rows.isEmpty else { continue }
        section.emptyState = nil
      }
      built.append(section)
    } // End of loop over host snapshots
    sections = built
    placeholder = built.isEmpty ? .noMatches(query: trimmed) : nil
  } // End of init(state:hostList:query:activities:selection:now:sshSetupStates:notes:…)

  /// Whether `text` contains `query`, ignoring case and diacritics.
  public static func matches(_ text: String, query: String) -> Bool {
    text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }

  /// "4 windows · 1 client", "1 window · 2 clients" or "2 windows · Detached". The client
  /// count says how many tmux clients are attached anywhere; it never says where.
  public static func countsText(windows: Int, clients: Int) -> String {
    let windowText = windows == 1 ? "1 window" : "\(windows) windows"
    guard clients > 0 else { return "\(windowText) · Detached" }
    let clientText = clients == 1 ? "1 client" : "\(clients) clients"
    return "\(windowText) · \(clientText)"
  }

  /// The empty-state text of a host that answered with no sessions.
  public static let emptyHostText = "No tmux sessions here. Use New session to start one."

  /// The caption of a host that was tried but never answered.
  public static let notReachedText = "Not reached yet"

  /// Whether `check` says which sessions are open in iTerm2 on this Mac: it worked, or iTerm2
  /// was not running (nothing is open in it). A failed check, or one that has not run, leaves
  /// that unknown (no session carries an attachment then, PLAN.md D16).
  public static func knowsWhatIsOpenHere(_ check: AttachmentCheck) -> Bool {
    switch check {
    case .checked, .iTermNotRunning: return true
    case .notChecked, .failed: return false
    }
  }

  /// The section for one host, before search filtering; `attachmentCheck` is this Mac's last
  /// iTerm2 check, which says whether a row with clients is attached elsewhere.
  static func section(
    for snapshot: HostSnapshot,
    attachmentCheck: AttachmentCheck,
    activities: [SessionKey: SessionActivity],
    selection: SessionKey?,
    now: Date
  ) -> HostSection {
    let isStale = snapshot.freshness == .stale
    let knowsOpenHere = Self.knowsWhatIsOpenHere(attachmentCheck)
    let rows = snapshot.sessions.map { session in
      let discovered = session.discovered
      let detail: String
      if isStale {
        detail = snapshot.lastSuccess.map { RelativeTime.lastSeen($0, now: now) } ?? "Not live"
      } else {
        detail = countsText(
          windows: discovered.windowCount, clients: discovered.attachedClientCount)
      }
      return SessionRow(
        key: session.key,
        name: discovered.name,
        hostName: snapshot.host.displayName,
        detail: detail,
        isStale: isStale,
        isOpenInITerm2Here: session.isOpenInITerm2Here,
        activity: activities[session.key],
        isSelected: session.key == selection,
        clientCount: discovered.attachedClientCount,
        knowsWhatIsOpenHere: knowsOpenHere)
    } // End of map over the host's sessions
    var caption: String?
    if let lastSuccess = snapshot.lastSuccess {
      caption = RelativeTime.lastChecked(lastSuccess, now: now)
    } else if snapshot.lastAttempt != nil {
      caption = notReachedText
    }
    let answered = snapshot.freshness == .live
    return HostSection(
      id: snapshot.host.id,
      name: snapshot.host.displayName,
      status: HostStatusLabel(snapshot),
      isRefreshing: snapshot.isRefreshing,
      caption: caption,
      problem: snapshot.lastError.flatMap(HostProblemText.explanation(for:)),
      emptyState: answered && rows.isEmpty ? emptyHostText : nil,
      rows: rows,
      offersSSHSetup: offersSSHSetup(snapshot))
  } // End of func section(for:attachmentCheck:activities:selection:now:)

  /// Whether `snapshot`'s host offers "Set up SSH in iTerm2 first" (PLAN.md D24): its last
  /// check needed a sign-in or had a host key problem, and it is an SSH host with a valid
  /// destination.
  static func offersSSHSetup(_ snapshot: HostSnapshot) -> Bool {
    switch snapshot.lastError {
    case .authFailed, .hostKeyProblem:
      return SSHSetupActions.isOffered(for: snapshot.host)
    default:
      return false
    }
  }

  /// The notices for the host list's load status and the last attachment check.
  static func notices(hostList: HostListStatus?, attachmentCheck: AttachmentCheck?) -> [Notice] {
    var notices: [Notice] = []
    switch hostList {
    case .invalid(let problem):
      notices.append(
        Notice(
          kind: .hostList,
          text: "muxFinder could not use its host list file and left it as it is. "
            + problem.message))
    case .unreadable(let message):
      notices.append(
        Notice(kind: .hostList, text: "muxFinder could not read its settings folder. " + message))
    case .saved, .notSavedYet, nil:
      break
    }
    if case .failed(_, let error) = attachmentCheck {
      var text = "muxFinder could not check which sessions are open in iTerm2 on this Mac."
      if let description = error?.errorDescription { text += " " + description }
      notices.append(Notice(kind: .attachmentCheck, text: text, fixIt: FixIt(error: error)))
    }
    return notices
  } // End of func notices(hostList:attachmentCheck:)
}
