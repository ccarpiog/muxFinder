import Foundation
import MuxFinderCore

/// What New session's folder search runs on (PLAN.md D36, Phase I-10b): its channel's
/// transport, clock and timings, and the preferences file its scope is read from. Only the
/// menu bar app in normal mode has one (`AppEnvironment.production`); tests pass a
/// `FakeFolderSearchTransport`, a clock they move and an `InMemoryPreferencesStore` (or a
/// `PreferencesStore` on a private folder).
public struct FolderSearchEnvironment: Sendable {
  /// Starts the folder-search scripts (`ProcessFolderSearchTransport` in the app).
  public var transport: any FolderSearchTransport
  /// Paces the channel's debounce, timeouts and quiet minute.
  public var clock: any AttachClock
  /// The channel's timings (150 ms, 10 s, 5 s, 60 s by default).
  public var configuration: FolderSearchChannel.Configuration
  /// Where the scope is read for each query (`preferences.json` in the app).
  public var preferences: any PreferencesStoring

  /// An environment from its parts.
  public init(
    transport: any FolderSearchTransport,
    clock: any AttachClock = SystemAttachClock(),
    configuration: FolderSearchChannel.Configuration = FolderSearchChannel.Configuration(),
    preferences: any PreferencesStoring
  ) {
    self.transport = transport
    self.clock = clock
    self.configuration = configuration
    self.preferences = preferences
  }
}

/// What VoiceOver last heard of the folders section (PLAN.md Phase I-10b).
enum FolderSearchAnnouncement: Sendable, Hashable {
  /// The section is not shown (the list is closed, or folder search does not apply).
  case hidden
  /// "Searching…" was said.
  case searching
  /// This summary was said ("3 folders found", "No folders found", …).
  case settled(String)
}

/// One New session window's folder search on one host (PLAN.md D36, Phase I-10b): its
/// `FolderSearchChannel`, the task reading the channel's states, and one queue for everything
/// asked of the channel (each search reads the scope from the preferences file first), so the
/// searches and the close keep their order. Made by the first searchable text; `close()` ends
/// it for good.
@MainActor
final class FolderSearchSession {
  /// Tells sessions apart: states from an ended one are ignored.
  let id: Int
  /// The New session draft's host.
  let hostID: UUID
  /// Where the channel searches.
  let host: FolderSearchHost
  /// The channel.
  let channel: FolderSearchChannel
  /// Where the scope is read.
  let preferences: any PreferencesStoring
  /// The latest queued request; the next one waits for it.
  private(set) var operation: Task<Void, Never>?
  /// Reads the channel's states.
  private var updates: Task<Void, Never>?

  /// A session for `host` over `environment`, handing each state the channel publishes to
  /// `onState`. Nothing starts until the first `search(_:)`.
  init(
    id: Int, hostID: UUID, host: FolderSearchHost, environment: FolderSearchEnvironment,
    onState: @escaping @MainActor @Sendable (FolderSearchState) -> Void
  ) {
    self.id = id
    self.hostID = hostID
    self.host = host
    preferences = environment.preferences
    let channel = FolderSearchChannel(
      transport: environment.transport, clock: environment.clock,
      configuration: environment.configuration)
    self.channel = channel
    updates = Task {
      for await state in await channel.updates() {
        onState(state)
      } // End of loop over the channel's states
    }
  } // End of init(id:hostID:host:environment:onState:)

  /// Searches `text` (as typed) in the scope `preferences.json` holds now (`home` when the
  /// file has none or cannot be used), queued after every earlier request.
  func search(_ text: String) {
    let channel = channel
    let preferences = preferences
    let host = host
    enqueue {
      let scope = await Self.scope(from: preferences)
      await channel.search(text, scope: scope, on: host)
    }
  }

  /// Tells the channel there is nothing to search (text it never sends, which cancels a query
  /// waiting for its debounce); its process stays until its quiet minute or `close()`.
  func stop() {
    let channel = channel
    let host = host
    enqueue { await channel.search("", scope: .standard, on: host) }
  }

  /// Ends the session: stops reading states and closes the channel once every earlier request
  /// went through (its processes reaped). Returns the task that ends with it.
  func close() -> Task<Void, Never> {
    updates?.cancel()
    updates = nil
    let channel = channel
    return enqueue { await channel.close() }
  }

  /// Runs `work` after every request queued before it; returns its task.
  @discardableResult
  private func enqueue(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
    let previous = operation
    let task = Task {
      await previous?.value
      await work()
    }
    operation = task
    return task
  }

  /// The folder search scope `preferences` holds now: `home` when it holds none, when the file
  /// cannot be used or when it cannot be read (PLAN.md D32, D36).
  nonisolated static func scope(from preferences: any PreferencesStoring) async
    -> FolderSearchScope
  {
    do throws(PreferencesStoreError) {
      return try await preferences.load().preferences.folderSearchScope
    } catch {
      return .standard
    }
  }
}

/// New session's folder search (PLAN.md D36, Phase I-10b; the "Folders on <host>" section of
/// the directory list, D31).
///
/// - **One channel per window and host** (`FolderSearchSession`), owned by the model: made by
///   the first searchable text (`FolderSearchSection.isSearchable(_:)`) while the list shows;
///   ended when the window closes (whatever closed it), when the draft's host changes and when
///   the app quits; its process also closes by itself after a quiet minute without a query
///   (`FolderSearchChannel.Configuration.quietPeriod`). The popover and the switcher never
///   make one (New session has its own window, D34).
/// - **Asking:** each edit of the field (and the list's opening, and a host change) asks the
///   channel for the field's text as typed when it can be searched, the scope read from
///   `preferences.json` first, so a change in Settings applies to the next query; text that
///   cannot be searched (a `/`, fewer than 2 characters) sends nothing and cancels a query
///   still waiting for its debounce. The channel debounces, keeps one query in flight and
///   drops older answers. Recent, Saved and Sessions never wait for any of it.
/// - **What shows:** the channel's states become `folderSearchState` (and an answer
///   `folderSearchPrevious`) on the main actor; the content builds the section from them
///   (`DirectoryPickerContent.folders`). Results stay in memory only and nothing about them is
///   logged.
/// - **VoiceOver:** "Searching…" once when a search starts from a settled section (not again
///   while it searches), and the section's summary when its search settles
///   (`folderAnnouncement()`); an edit's announcement says the directory count and this in one.
extension AppModel {
  // MARK: - Content

  /// What the content's folders section is built from, or `nil` when there is no folder search
  /// (no `AppEnvironment.folderSearch`, or a fixture without one).
  var folderSearchSnapshot: FolderSearchSnapshot? {
    guard environment?.folderSearch != nil || showsFolderSearchFixture else { return nil }
    return FolderSearchSnapshot(state: folderSearchState, previous: folderSearchPrevious)
  }

  // MARK: - The channel

  /// Brings the folder search in line with the window: while it shows, its list is open, the
  /// draft is not busy and the field's text can be searched on the draft's host, the channel
  /// for that host is asked for the text (made first if needed; one for another host is ended);
  /// otherwise a search still waiting is cancelled. The same text is not asked twice in a row.
  func updateFolderSearch() {
    guard let folderEnvironment = environment?.folderSearch, lifecycle != .stopped else { return }
    let draft = newSessionDraft
    guard isNewSessionShown, directoryPicker.isOpen, !draft.isBusy,
      let hostID = draft.hostID, let host = host(withID: hostID),
      FolderSearchSection.isSearchable(draft.directory)
    else {
      pauseFolderSearch()
      return
    }
    let searchHost = FolderSearchHost(host)
    if let session = folderSearchSession, session.hostID != hostID || session.host != searchHost {
      endFolderSearch()
    }
    let session =
      folderSearchSession
      ?? startFolderSearchSession(hostID: hostID, host: searchHost, environment: folderEnvironment)
    if let asked = folderSearchAsked, DirectoryLists.same(asked, draft.directory) { return }
    folderSearchAsked = draft.directory
    session.search(draft.directory)
  } // End of func updateFolderSearch()

  /// Makes the window's session for `host` (the draft's `hostID`).
  private func startFolderSearchSession(
    hostID: UUID, host: FolderSearchHost, environment: FolderSearchEnvironment
  ) -> FolderSearchSession {
    nextFolderSearchSessionID += 1
    let id = nextFolderSearchSessionID
    let session = FolderSearchSession(
      id: id, hostID: hostID, host: host, environment: environment,
      onState: { [weak self] state in self?.folderSearchStateChanged(state, session: id) })
    folderSearchSession = session
    folderSearchState = nil
    folderSearchPrevious = nil
    return session
  } // End of func startFolderSearchSession(hostID:host:environment:)

  /// Cancels a search still waiting (the text can no longer be searched, or the list closed
  /// before it was asked); the channel stays for the next one.
  private func pauseFolderSearch() {
    guard let session = folderSearchSession, folderSearchAsked != nil else { return }
    folderSearchAsked = nil
    session.stop()
  }

  /// Ends the window's folder search, if any: the channel closes in the background (its
  /// processes reaped; quitting waits for it), its states are no longer shown and nothing
  /// found is kept.
  func endFolderSearch() {
    folderSearchAsked = nil
    folderSearchState = nil
    folderSearchPrevious = nil
    lastFolderAnnouncement = .hidden
    guard let session = folderSearchSession else { return }
    folderSearchSession = nil
    let id = session.id
    let closing = session.close()
    folderSearchClosings[id] = closing
    Task { [weak self] in
      await closing.value
      self?.folderSearchClosings[id] = nil
    }
  } // End of func endFolderSearch()

  /// The New session window closed (Cancel, Esc, ⌘W, its close button, a success, "Open
  /// existing"): its folder search ends and its explanation hides.
  func newSessionWindowClosed() {
    endFolderSearch()
    isFolderSearchHelpShown = false
  }

  /// The draft's host changed: the folder search on the old host ends, and the field's text is
  /// searched on the new one while the list shows (said only once it settles).
  func newSessionHostChanged() {
    if let session = folderSearchSession, session.hostID != newSessionDraft.hostID {
      endFolderSearch()
    }
    updateFolderSearch()
    _ = folderAnnouncement()
  }

  /// The channel of session `id` published `state`: it becomes what the section shows (an
  /// answer is also kept as the previous one), and VoiceOver hears what changed.
  func folderSearchStateChanged(_ state: FolderSearchState, session id: Int) {
    guard folderSearchSession?.id == id else { return }
    folderSearchState = state
    if case .answered(let answer) = state.phase, let host = state.host {
      folderSearchPrevious = FolderSearchPreviousAnswer(
        host: host, text: state.text, scope: state.scope, paths: answer.paths,
        header: state.header)
    }
    if let text = folderAnnouncement() { announce?(text) }
  }

  /// Quitting: ends the folder search and waits for every channel still closing, each for at
  /// most the session actions' budget.
  func stopFolderSearch() async {
    endFolderSearch()
    let budget = environment?.sessionActionShutdownBudget ?? Self.sessionActionShutdownBudget
    for closing in Array(folderSearchClosings.values) {
      _ = await Self.ends(closing, within: budget)
    } // End of loop over the closings
  }

  /// Returns once every request queued on the folder search so far (searches, the close of an
  /// ended channel) went through (tests).
  func folderSearchRequestsHandled() async {
    await folderSearchSession?.operation?.value
    for closing in Array(folderSearchClosings.values) { await closing.value }
  }

  // MARK: - VoiceOver

  /// What VoiceOver should hear of the folders section now, if anything, and remembers it:
  /// "Searching…" when a search starts from a settled (or hidden) section, never again while
  /// it searches; the section's summary when it settles or its summary changes; nothing while
  /// the section is hidden.
  func folderAnnouncement() -> String? {
    let shows = isNewSessionShown && directoryPicker.isOpen
    let section = shows ? directoryPickerContent?.folders : nil
    let current: FolderSearchAnnouncement
    if let section {
      current = section.status.isSettled ? .settled(section.summary) : .searching
    } else {
      current = .hidden
    }
    let previous = lastFolderAnnouncement
    lastFolderAnnouncement = current
    guard current != previous else { return nil }
    switch current {
    case .hidden: return nil
    case .searching: return FolderSearchSection.searchingTitle
    case .settled(let summary): return summary
    }
  } // End of func folderAnnouncement()

  // MARK: - "Missing a folder?"

  /// "Missing a folder?" in the folders section: shows or hides its explanation.
  public func toggleFolderSearchHelp() {
    isFolderSearchHelpShown.toggle()
  }

  /// "Open muxFinder Settings" in the explanation: Settings opens on its Directories tab,
  /// where the scope is set. Does nothing for a fixture.
  public func openFolderSearchSettings() {
    guard environment != nil else { return }
    settings.selectedTab = .directories
    openSettings()
  }

  /// "Open Spotlight settings" in This Mac's explanation: This Mac's Spotlight pane in System
  /// Settings, through `AppEnvironment.openURL`. Does nothing for a fixture.
  public func openSpotlightSettings() {
    environment?.openURL(FolderSearchSection.spotlightSettingsURL)
  }
}
