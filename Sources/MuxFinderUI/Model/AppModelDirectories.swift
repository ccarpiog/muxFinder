import Foundation
import MuxFinderCore
import os

/// New session's directories in the popover (PLAN.md D31): the directory list under the
/// Directory field, its keys, "Save this directory", "Clear recent directories on <host>", and
/// the recording of a recent directory when a creation made a session.
///
/// - **One store, one queue:** every load and change goes through `AppEnvironment.directories`
///   (`DirectoryStore` on `directories.json` in the app, an `InMemoryDirectoryStore` in the
///   self-tests, none in fixtures and the tests of other parts), one operation after another
///   (`enqueueDirectoryOperation(_:)`), in the background. The lists are read afresh each time
///   New session opens; each change's result becomes the lists shown.
/// - **An in-popover list, not a menu:** the list is drawn inside the popover panel, so its keys
///   go through `PopoverKey` and `handle(_:)` like the popover's others, and the preview
///   galleries render it (D31 records why a SwiftUI `Menu` or `NSMenu` was not used).
/// - **Picking only fills the field:** the Directory field then holds the entry as typed text
///   would, and the draft checks it (`NewSessionDraft.directoryIssue`, `request(hosts:command:)`)
///   before any request, whatever its source (D3, D18).
/// - **Failures never fail anything:** a refused save or clear leaves the lists as they were,
///   says why in the list, and is logged by its code only, never a directory.
extension AppModel {
  // MARK: - Content

  /// What the directory list shows for the draft's host, or `nil` with no host chosen (or one
  /// the engine no longer lists).
  public var directoryPickerContent: DirectoryPickerContent? {
    guard let hostID = newSessionDraft.hostID, let snapshot = refreshState?.snapshot(of: hostID)
    else { return nil }
    return DirectoryPickerContent(
      host: snapshot.host, lists: directoryLists, sessions: snapshot.sessions,
      field: newSessionDraft.directory, status: directoryStatus,
      canChange: isPreview || environment?.directories != nil)
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

  /// Opens the list under the Directory field (⌥↓ highlights its first row). Only while New
  /// session shows and is not busy, with a host chosen.
  public func openDirectoryList(highlightingFirst: Bool) {
    guard case .newSession = panel, !newSessionDraft.isBusy,
      let content = directoryPickerContent
    else { return }
    directoryPicker = DirectoryPickerState(
      isOpen: true, highlighted: highlightingFirst ? content.items.first : nil)
  }

  /// Closes the list (Esc, picking an entry, the button, the panel closing) and forgets its
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
  /// change, compared byte for byte, ends the list's navigation, so the highlight goes (the list
  /// stays open, and ↓ or the pointer starts again) and Return creates from the field instead of
  /// picking a row highlighted before the edit.
  func directoryFieldChanged(from previous: String) {
    guard directoryPicker.highlighted != nil,
      !DirectoryLists.same(previous, newSessionDraft.directory)
    else { return }
    directoryPicker.highlighted = nil
  }

  /// The open list's keys (`handle(_:)` asks first while New session shows): ↑/↓ (and ⌥↓) move
  /// the highlight, Return picks it (with none, closes the list and creates, as Return in the
  /// field does; editing the field drops the highlight, `directoryFieldChanged(from:)`), Esc
  /// closes the list and leaves the panel open. `nil` while the list is closed and for every
  /// other key, which then behave as without the list.
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
  /// checks like typed text) and closes the list; an action runs ("Save this directory",
  /// "Clear recent directories on <host>"), the list staying open. Only a row the list shows
  /// and has on, while New session shows and is not busy.
  public func pickDirectoryItem(_ item: DirectoryPickerContent.Item) {
    guard case .newSession = panel, !newSessionDraft.isBusy,
      directoryPickerContent?.items.contains(item) == true
    else { return }
    switch item {
    case .entry(_, let directory):
      newSessionDraft.directory = directory
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
