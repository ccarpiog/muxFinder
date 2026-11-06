import Foundation
import MuxFinderCore
import os

/// New session's directories (PLAN.md D31; in the New session window, D34): the directory list
/// under the Directory field, its keys, "Save this directory", "Clear recent directories on
/// <host>", and the recording of a recent directory when a creation made a session.
///
/// - **One store, one queue:** every load and change goes through `AppEnvironment.directories`
///   (`DirectoryStore` on `directories.json` in the app, an `InMemoryDirectoryStore` in the
///   self-tests, none in fixtures and the tests of other parts), one operation after another
///   (`enqueueDirectoryOperation(_:)`), in the background. The lists are read afresh each time
///   New session opens; each change's result becomes the lists shown.
/// - **An in-window list, not a menu:** the list is drawn inside the New session window, so its
///   keys go through `PopoverKey` and `handleNewSessionKey(_:)` like the window's others, and
///   the preview galleries render it (D31 records why a SwiftUI `Menu` or `NSMenu` was not
///   used).
/// - **Picking only fills the field:** the Directory field then holds the entry as typed text
///   would, and the draft checks it (`NewSessionDraft.directoryIssue`, `request(hosts:command:)`)
///   before any request, whatever its source (D3, D18).
/// - **A folder dropped from Finder** on the field's row (D34, Phase I-9b) fills the field as a
///   pick does, its path written `~/…` under This Mac's home folder (`FolderDrop`,
///   `dropOnDirectoryField(_:)`); anything else is refused, and the field shows a highlight only
///   while a drop would fill it (`directoryDragMoved(_:)`).
/// - **The field is the list's search** (Phase I-7): the content is filtered by the field's
///   text (`DirectoryPickerContent`), and a user edit of the field opens the list while an
///   entry matches and closes it again when none does or the field is left empty, unless the
///   button or ⌥↓ opened it (`DirectoryPickerState.Opening`); VoiceOver hears the match count
///   (`announce`).
/// - **Failures never fail anything:** a refused save or clear leaves the lists as they were,
///   says why in the list, and is logged by its code only, never a directory.
extension AppModel {
  // MARK: - Content

  /// What the directory list shows for the draft's host, filtered by the Directory field, or
  /// `nil` with no host chosen (or one the engine no longer lists).
  public var directoryPickerContent: DirectoryPickerContent? {
    directoryPickerContent(field: newSessionDraft.directory)
  }

  /// What the directory list would show for the draft's host with `field` in the Directory
  /// field (This Mac's home folder for the `~` rule), or `nil` with no host chosen.
  func directoryPickerContent(field: String) -> DirectoryPickerContent? {
    guard let hostID = newSessionDraft.hostID, let snapshot = refreshState?.snapshot(of: hostID)
    else { return nil }
    return DirectoryPickerContent(
      host: snapshot.host, lists: directoryLists, sessions: snapshot.sessions,
      field: field, status: directoryStatus,
      canChange: isPreview || environment?.directories != nil, thisMacHome: thisMacHome)
  }

  /// The highlighted row, while the list is open and still has it (a host change or a clear
  /// may take it away).
  public var highlightedDirectoryItem: DirectoryPickerContent.Item? {
    guard directoryPicker.isOpen, let item = directoryPicker.highlighted,
      directoryPickerContent?.items.contains(item) == true
    else { return nil }
    return item
  }

  // MARK: - Opening and moving

  /// The pull-down button (or Space on it): opens the list, or closes it when open.
  public func toggleDirectoryList() {
    if directoryPicker.isOpen {
      closeDirectoryList()
    } else {
      openDirectoryList(highlightingFirst: false)
    }
  }

  /// Opens the list under the Directory field at the user's request (the button, ⌥↓, which
  /// highlights its first row), so it stays open whatever the field holds. Only while New
  /// session shows and is not busy, with a host chosen.
  public func openDirectoryList(highlightingFirst: Bool) {
    guard isNewSessionShown, !newSessionDraft.isBusy,
      let content = directoryPickerContent
    else { return }
    directoryPicker = DirectoryPickerState(
      opening: .request, highlighted: highlightingFirst ? content.items.first : nil)
  }

  /// Closes the list (Esc, picking an entry, the button, the window closing) and forgets its
  /// highlight and problem.
  public func closeDirectoryList() {
    directoryPicker = DirectoryPickerState()
  }

  /// ↓ (`down`) or ↑ in the open list: the next or previous row, staying at the ends; from no
  /// highlight, ↓ the first row and ↑ the last.
  public func moveDirectoryHighlight(down: Bool) {
    guard directoryPicker.isOpen, let content = directoryPickerContent else { return }
    directoryPicker.highlighted = content.item(
      movingFrom: highlightedDirectoryItem, down: down)
  }

  /// The pointer over a row highlights it, so the mouse and the keys share one highlight.
  public func highlightDirectoryItem(_ item: DirectoryPickerContent.Item) {
    guard directoryPicker.isOpen, directoryPickerContent?.items.contains(item) == true else {
      return
    }
    directoryPicker.highlighted = item
  }

  /// The Directory field's text changed from `previous` (`newSessionDraft`'s observer): any
  /// change, compared byte for byte, ends the list's navigation, so the highlight goes (↓ or
  /// the pointer starts again) and Return creates from the field instead of picking a row
  /// highlighted before the edit. A change the model made itself (a pick) ends there; the
  /// user's edit then opens or closes the list (`directoryFieldEdited(from:)`). A host change or
  /// the draft's reset leaves the text alone or happens while New session is not shown, so it
  /// is no edit.
  func directoryFieldChanged(from previous: String) {
    guard !DirectoryLists.same(previous, newSessionDraft.directory) else { return }
    if directoryPicker.highlighted != nil { directoryPicker.highlighted = nil }
    guard !isFillingDirectoryField else { return }
    directoryFieldEdited(from: previous)
  }

  /// The user edited the Directory field from `previous` (typing, pasting), while New session
  /// shows, not busy, with a host chosen (PLAN.md D31, Phase I-7). With an entry matching the
  /// new text, a closed list opens, highlighting nothing (Return still creates from the field;
  /// ↓ or ⌥↓ highlights the first match). With none matching, or the field left empty (which
  /// shows the whole list but never opens it), a list the typing opened closes, and one the
  /// button or ⌥↓ opened stays. Then the match count is announced
  /// (`announceDirectoryMatches(_:previous:wasOpen:)`).
  func directoryFieldEdited(from previous: String) {
    guard isNewSessionShown, !newSessionDraft.isBusy,
      let content = directoryPickerContent
    else { return }
    let wasOpen = directoryPicker.isOpen
    let openedByTyping = directoryPicker.opening == .typing
    if content.query.isEmpty || content.matchCount == 0 {
      if openedByTyping { closeDirectoryList() }
    } else if !wasOpen {
      directoryPicker = DirectoryPickerState(opening: .typing)
    }
    announceDirectoryMatches(content, previous: previous, wasOpen: wasOpen)
  } // End of func directoryFieldEdited(from:)

  /// Tells VoiceOver what an edit of the Directory field did to the list (`content` after it,
  /// `previous` the text before it): while the list shows, its match count
  /// (`DirectoryPickerContent.matchSummary`) when the edit opened it or changed the rows shown
  /// (an edit that keeps the same rows says nothing again); "No matching directories" when the
  /// edit closed a list the typing had opened because nothing matches. Clearing the field,
  /// which closes such a list, and an edit while the list stays closed say nothing.
  func announceDirectoryMatches(
    _ content: DirectoryPickerContent,
    previous: String,
    wasOpen: Bool
  ) {
    guard let announce else { return }
    if directoryPicker.isOpen {
      guard !wasOpen || directoryPickerContent(field: previous)?.sections != content.sections
      else { return }
      announce(content.matchSummary)
    } else if wasOpen, !content.query.isEmpty {
      announce(DirectoryPickerContent.noMatchesTitle)
    }
  } // End of func announceDirectoryMatches(_:previous:wasOpen:)

  /// Fills the Directory field with `directory` for the user (a pick): the highlight goes, as
  /// with any change, but it is no edit, so the list is neither opened nor closed by it and
  /// nothing is announced.
  func fillDirectoryField(_ directory: String) {
    isFillingDirectoryField = true
    defer { isFillingDirectoryField = false }
    newSessionDraft.directory = directory
  }

  /// The open list's keys (`handleNewSessionKey(_:)` asks first): ↑/↓ (and ⌥↓) move
  /// the highlight through the rows shown (the filter's), Return picks it (with none, as after
  /// the typing opened the list, closes the list and creates, as Return in the field does;
  /// editing the field drops the highlight, `directoryFieldChanged(from:)`), Esc closes the
  /// list, keeping the field's text, and leaves the window open. `nil` while the list is closed
  /// and for every other key, which then behave as without the list.
  func handleDirectoryListKey(_ key: PopoverKey) -> PopoverKeyResult? {
    guard directoryPicker.isOpen else { return nil }
    switch key {
    case .up:
      moveDirectoryHighlight(down: false)
    case .down, .openList:
      moveDirectoryHighlight(down: true)
    case .open:
      if let item = highlightedDirectoryItem {
        pickDirectoryItem(item)
      } else {
        closeDirectoryList()
        createSession()
      }
    case .close:
      closeDirectoryList()
    case .find, .refresh, .newSession, .settings:
      return nil
    }
    return .handled
  } // End of func handleDirectoryListKey(_:)

  // MARK: - Picking

  /// Picks a row of the list: a directory fills the Directory field (which the draft then
  /// checks like typed text; the fill is no edit, so it never reopens the list,
  /// `fillDirectoryField(_:)`) and closes the list; an action runs ("Save this directory",
  /// "Clear recent directories on <host>"), the list staying open. Only a row the list shows
  /// (after the filter) and has on, while New session shows and is not busy.
  public func pickDirectoryItem(_ item: DirectoryPickerContent.Item) {
    guard isNewSessionShown, !newSessionDraft.isBusy,
      directoryPickerContent?.items.contains(item) == true
    else { return }
    switch item {
    case .entry(_, let directory):
      fillDirectoryField(directory)
      closeDirectoryList()
    case .action(.saveDirectory):
      saveFieldDirectory()
    case .action(.clearRecents):
      clearRecentDirectories()
    }
  } // End of func pickDirectoryItem(_:)

  /// "Save this directory": adds the Directory field's value, as typed, to the saved list
  /// shared by every host. Only while the list has it on (`DirectoryPickerContent.saveIssue`).
  public func saveFieldDirectory() {
    guard lifecycle != .stopped, let content = directoryPickerContent, content.canSaveDirectory
    else { return }
    changeDirectoryLists(
      .addSaved(newSessionDraft.directory), hostID: nil,
      problem: "muxFinder couldn't save this directory.")
  }

  /// "Clear recent directories on <host>": forgets the draft's host's recent directories (the
  /// saved list and other hosts' recents stay). Only while the list has it on.
  public func clearRecentDirectories() {
    guard lifecycle != .stopped, let hostID = newSessionDraft.hostID,
      let content = directoryPickerContent, content.canClearRecents
    else { return }
    changeDirectoryLists(
      .clearRecents(hostID: hostID), hostID: hostID,
      problem: "muxFinder couldn't clear the recent directories.")
  }

  // MARK: - A folder dropped from Finder (PLAN.md D34, Phase I-9b)

  /// What dropping `items` on the Directory field's row would do now: `FolderDrop`'s outcome
  /// over This Mac's home folder (`thisMacHome`, the directory list's `~` rule), for every
  /// host; refused as `unavailable` while the window is closed, the draft busy (its fields are
  /// off) or after `shutdown()`.
  public func directoryDropOutcome(_ items: [FolderDrop.Item]) -> FolderDrop.Outcome {
    guard isNewSessionShown, !newSessionDraft.isBusy, lifecycle != .stopped else {
      return .refused(.unavailable)
    }
    return FolderDrop.outcome(for: items, home: thisMacHome)
  }

  /// A drag of `items` entered or moved over the Directory field's row: the field shows the
  /// drop highlight (`isDirectoryDropTargeted`) while the drop would fill it, and not
  /// otherwise. Returns whether it would.
  @discardableResult
  public func directoryDragMoved(_ items: [FolderDrop.Item]) -> Bool {
    let fills = directoryDropOutcome(items).text != nil
    if isDirectoryDropTargeted != fills { isDirectoryDropTargeted = fills }
    return fills
  }

  /// The drag left the Directory field's row, or ended: the highlight goes.
  public func directoryDragEnded() {
    if isDirectoryDropTargeted { isDirectoryDropTargeted = false }
  }

  /// `items` dropped on the Directory field's row: the highlight goes and, for one folder, the
  /// field takes its path (`directoryDropOutcome(_:)`) as a pick (`fillDirectoryField(_:)`: no
  /// edit, so the list does not reopen and nothing is announced), replacing what it held, and
  /// the directory list closes. The draft then checks the text like typed text (PLAN.md D31).
  /// Anything else changes nothing. Returns whether the field was filled. Never logs the path.
  @discardableResult
  public func dropOnDirectoryField(_ items: [FolderDrop.Item]) -> Bool {
    directoryDragEnded()
    guard let text = directoryDropOutcome(items).text else { return false }
    fillDirectoryField(text)
    closeDirectoryList()
    return true
  }

  // MARK: - The store

  /// Reads the directory lists afresh (New session opening), in the queue; the result becomes
  /// the lists and status shown. Reading never writes. A problem the status did not have yet is
  /// logged by its code only.
  func loadDirectoryLists() {
    guard lifecycle != .stopped else { return }
    enqueueDirectoryOperation { [weak self] store in
      let status: DirectoryListStatus
      let lists: DirectoryLists
      do throws(DirectoryStoreError) {
        let result = try await store.load()
        status = DirectoryListStatus(result)
        lists = result.lists
      } catch {
        status = .unreadable(error.errorDescription ?? "The folder is not usable.")
        lists = DirectoryLists()
      }
      await self?.directoryListsLoaded(lists, status: status)
    }
  } // End of func loadDirectoryLists()

  /// A load ended: shows `lists` with `status`, logging a problem status that is new.
  func directoryListsLoaded(_ lists: DirectoryLists, status: DirectoryListStatus) async {
    let previous = directoryStatus
    directoryLists = lists
    directoryStatus = status
    guard !status.acceptsChanges, status != previous else { return }
    logger.error("Directory list not usable: \(status.code, privacy: .public)")
    await environment?.diagnostics?.record(
      .settings, outcome: .failure, detail: "directory list not usable: \(status.code)")
  }

  /// Applies `change` (for `hostID`'s list, if it is a host's) in the queue, forgetting the
  /// recents of hosts no longer in the host list. The result becomes the lists shown (and
  /// Settings' saved list, when it has no unsaved edits). A failure leaves the lists as they
  /// were, shows `problem` and the store's explanation in the list, and is logged by code only.
  func changeDirectoryLists(_ change: DirectoryListChange, hostID: UUID?, problem: String) {
    let knownHosts = knownHostIDs
    enqueueDirectoryOperation { [weak self] store in
      do throws(DirectoryStoreError) {
        let result = try await store.apply(change, knownHosts: knownHosts)
        self?.directoriesChanged(result.lists, tellingSettings: true)
        if let kept = result.displacedFileError {
          await self?.recordDirectoryFailure(
            "directory list: \(change.kind): displaced file not kept: \(kept.code)",
            hostID: hostID)
        }
      } catch {
        guard let self else { return }
        if case .fileNotUsable(let file) = error { directoryStatus = .fileNotUsable(file) }
        if directoryPicker.isOpen {
          directoryPicker.problem = [problem, error.errorDescription].compactMap { $0 }
            .joined(separator: " ")
        }
        await recordDirectoryFailure(
          "directory list: \(change.kind) not done: \(error.code)", hostID: hostID)
      }
    }
  } // End of func changeDirectoryLists(_:hostID:problem:)

  /// The lists changed (a change here, or a save in Settings): they become the lists shown,
  /// from a usable file; with `tellingSettings`, Settings' Directories tab takes them too.
  func directoriesChanged(_ lists: DirectoryLists, tellingSettings: Bool) {
    directoryLists = lists
    directoryStatus = .usable(droppedEntryCount: 0)
    directoryPicker.problem = nil
    if tellingSettings { settings.directoriesChangedElsewhere(lists) }
  }

  /// Logs a failed directory change by its code (`detail` never holds a directory).
  func recordDirectoryFailure(_ detail: String, hostID: UUID?) async {
    logger.error("\(detail, privacy: .public)")
    await environment?.diagnostics?.record(
      .settings, outcome: .failure, hostID: hostID?.uuidString, detail: detail)
  }

  /// Records `directory` (as New session checked it) as `hostID`'s newest recent directory
  /// (PLAN.md D31), once a creation made a session there: before the session's attach, so an
  /// attach that fails afterwards changes nothing. An empty field (`nil`, the home folder)
  /// records nothing, and neither does a collision, a failed creation or `mayHaveCreated`,
  /// which never report a created session. The recents of hosts no longer in the host list
  /// (`knownHostIDs`) are forgotten in the same write. The store is written in the background,
  /// in the queue; the result becomes the lists shown. A failure is logged by its kind only,
  /// never the directory, and never blocks or fails the creation or its attach.
  func recordRecentDirectory(_ directory: String?, for hostID: UUID) {
    guard let directory, !directory.isEmpty else { return }
    let knownHosts = knownHostIDs
    let diagnostics = environment?.diagnostics
    let logger = self.logger
    enqueueDirectoryOperation { [weak self] store in
      let failure: String?
      do throws(DirectoryStoreError) {
        let result = try await store.apply(
          .recordRecent(directory, hostID: hostID), knownHosts: knownHosts)
        self?.directoriesChanged(result.lists, tellingSettings: true)
        failure = result.displacedFileError.map { "displaced file not kept: \($0.code)" }
      } catch {
        if case .fileNotUsable(let file) = error { self?.directoryStatus = .fileNotUsable(file) }
        failure = "not recorded: \(error.code)"
      }
      guard let failure else {
        logger.info("Recent directory recorded")
        return
      }
      logger.error("Recent directory \(failure, privacy: .public)")
      await diagnostics?.record(
        .settings, outcome: .failure, hostID: hostID.uuidString,
        detail: "recent directory \(failure)")
    }
  } // End of func recordRecentDirectory(_:for:)

  /// Runs `work` on the directory store after every operation queued before it, in a task
  /// `shutdown()` waits for (within its budget). Nothing runs without a store (a fixture, a
  /// test of another part).
  func enqueueDirectoryOperation(
    _ work: @escaping @MainActor @Sendable (any DirectoryStoring) async -> Void
  ) {
    guard let store = environment?.directories else { return }
    let previous = directoryOperation
    directoryOperation = Task {
      await previous?.value
      await work(store)
    }
  }

  /// Returns once every directory store operation started so far (loads, recordings, saves,
  /// clears) has ended.
  func directoryRecordingsHandled() async {
    await directoryOperation?.value
  }
}
