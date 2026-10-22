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
  /// Work in progress on the session, or its last failure.
  public var activity: SessionActivity?
  /// Whether the keyboard selection is on this row.
  public var isSelected: Bool

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

    /// `Identifiable` conformance: the kind (at most one notice of each).
    public var id: Kind { kind }
  }

  /// The host groups, in host-list order, after search filtering.
  public var sections: [HostSection]
  /// What replaces the host list, if anything.
  public var placeholder: Placeholder?
  /// Problems shown above the host list.
  public var notices: [Notice]

  /// The rows the keyboard moves through, top to bottom.
  public var selectableKeys: [SessionKey] { sections.flatMap { $0.rows.map(\.key) } }

  /// The content for `state` (`nil` while loading) with the search `query`, the sessions'
  /// `activities`, the keyboard `selection`, and relative times seen at `now`.
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
    now: Date
  ) {
    notices = Self.notices(hostList: hostList, attachmentCheck: state?.attachmentCheck)
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
        for: snapshot, activities: activities, selection: selection, now: now)
      if !trimmed.isEmpty, !Self.matches(snapshot.host.displayName, query: trimmed) {
        section.rows = section.rows.filter { Self.matches($0.name, query: trimmed) }
        guard !section.rows.isEmpty else { continue }
        section.emptyState = nil
      }
      built.append(section)
    } // End of loop over host snapshots
    sections = built
    placeholder = built.isEmpty ? .noMatches(query: trimmed) : nil
  } // End of init(state:hostList:query:activities:selection:now:)

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

  /// The section for one host, before search filtering.
  static func section(
    for snapshot: HostSnapshot,
    activities: [SessionKey: SessionActivity],
    selection: SessionKey?,
    now: Date
  ) -> HostSection {
    let isStale = snapshot.freshness == .stale
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
        isSelected: session.key == selection)
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
      rows: rows)
  } // End of func section(for:activities:selection:now:)

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
      notices.append(Notice(kind: .attachmentCheck, text: text))
    }
    return notices
  } // End of func notices(hostList:attachmentCheck:)
}
