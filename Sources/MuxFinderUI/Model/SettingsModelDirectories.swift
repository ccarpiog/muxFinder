import Foundation
import MuxFinderCore

/// The Directories tab: New session's saved directories, shared by every host (PLAN.md D31).
///
/// - **Save and Revert, as the host editor (D23):** the tab edits a working copy
///   (`directoryDraft`): "Add" (checked inline with the store's entry rules, which include
///   `Validation.workingDirectory`, plus no duplicate and the 50-entry cap), remove, move up and
///   down. Nothing is written until "Save", which applies the edits in one change through
///   `SettingsEnvironment.directories` (the store New session uses):
///   `DirectoryListChange.mergeSaved(base:edited:)`, with `directoryDraftBase` (the saved list
///   the edits started from) and the working copy. The store merges them, under its lock, into
///   the saved list as it is then, so a directory New session (or another muxFinder) saved or
///   removed meanwhile is neither lost nor brought back; recent directories are never touched
///   here. "Revert" brings back the list as last loaded, saved or changed elsewhere. Closing
///   the window drops unsaved edits: the next opening reads the file again.
/// - **An unusable file** (or an unreadable folder) is shown with its notice and offers no edit,
///   since the store would refuse every change; "Try again" reads it again once it is fixed or
///   moved away. A usable file whose entries were partly left out is editable, and its notice
///   says so (the store keeps that file as a backup at the save).
/// - **Changes elsewhere:** New session's "Save this directory", a clear and a recording give
///   the tab the lists they left (`directoriesChangedElsewhere(_:)`): the saved list shown
///   follows them while the tab has no unsaved edits; with edits, only what "Revert" brings
///   back does, and "Save" keeps the change through its merge.
/// - **Logs** carry kinds and counts only, never a directory.
extension SettingsModel {
  /// Whether the tab offers edits: the lists loaded from a usable file (or none yet).
  public var areDirectoriesEditable: Bool {
    if case .usable = directoryStatus { return true }
    return false
  }

  /// The tab's notice: an unusable file, an unreadable folder, or entries left out (with what
  /// the save does about it). `nil` when there is nothing to say.
  public var directoryNotice: String? {
    guard let notice = directoryStatus.notice else { return nil }
    if case .usable = directoryStatus {
      return notice + " When you save, the current file is kept as a backup in muxFinder's "
        + "settings folder."
    }
    return notice
  }

  /// Whether "Try again" is offered: the file or the folder could not be used.
  public var offersDirectoryReload: Bool { !directoryStatus.acceptsChanges }

  /// The "Add" field's problem, inline: a rule the typed directory breaks, a directory in the
  /// list already (exact string) or a full list. `nil` while the field is empty.
  public var newDirectoryIssue: String? {
    guard !newDirectory.isEmpty else { return nil }
    do throws(DirectoryListError) {
      _ = try DirectoryLists.check(newDirectory)
    } catch {
      return error.message
    }
    if directoryDraft.contains(where: { DirectoryLists.same($0, newDirectory) }) {
      return "This directory is in the list already."
    }
    if directoryDraft.count >= DirectoryLists.maximumSavedCount {
      return DirectoryListError.tooManySaved.message
    }
    return nil
  } // End of var newDirectoryIssue

  /// Whether "Add" is on: an editable list and a typed directory with no problem.
  public var canAddDirectory: Bool {
    areDirectoriesEditable && !newDirectory.isEmpty && newDirectoryIssue == nil
  }

  /// Whether the working copy differs from the list as last loaded, saved or changed elsewhere
  /// (exact strings, byte for byte: `DirectoryLists.sameEntries(_:_:)`).
  public var isDirectoryListDirty: Bool {
    !DirectoryLists.sameEntries(directoryDraft, savedDirectories)
  }

  /// Whether "Save" is on: an editable list with unsaved edits, no save running.
  public var canSaveDirectories: Bool {
    areDirectoriesEditable && isDirectoryListDirty && !isSavingDirectories && !isShutDown
  }

  // MARK: - Editing

  /// "Add" (or Return in the field): appends the typed directory, as typed, to the working
  /// copy and empties the field. Only while `canAddDirectory`.
  public func addDirectory() {
    guard canAddDirectory else { return }
    directoryDraft.append(newDirectory)
    newDirectory = ""
    directorySaveNotice = nil
  }

  /// Removes the entry at `index` from the working copy.
  public func removeDirectory(at index: Int) {
    guard areDirectoriesEditable, directoryDraft.indices.contains(index) else { return }
    directoryDraft.remove(at: index)
    directorySaveNotice = nil
  }

  /// Moves the entry at `index` one place up (`offset` -1) or down (+1) in the working copy;
  /// nothing past either end.
  public func moveDirectory(at index: Int, by offset: Int) {
    let destination = index + offset
    guard areDirectoriesEditable, directoryDraft.indices.contains(index),
      directoryDraft.indices.contains(destination), offset != 0
    else { return }
    directoryDraft.swapAt(index, destination)
    directorySaveNotice = nil
  }

  /// "Revert": the working copy goes back to the list as last loaded, saved or changed
  /// elsewhere, which becomes the base of the next edits; the field and the last save's
  /// messages are cleared.
  public func revertDirectories() {
    directoryDraft = savedDirectories
    directoryDraftBase = savedDirectories
    newDirectory = ""
    directorySaveError = nil
    directorySaveNotice = nil
  }

  // MARK: - Loading and saving

  /// Reads the saved directories (the window's opening, "Try again"); reading never writes.
  /// The working copy becomes what was read, the field and messages are cleared. A problem is
  /// logged by its code only. Does nothing without a store, after `shutdown()`, or when the
  /// window opened as another generation meanwhile.
  public func loadDirectories() async {
    guard let store = environment?.directories, !isShutDown else { return }
    let generation = windowGeneration
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
    guard windowGeneration == generation, !isShutDown else { return }
    directoryStatus = status
    savedDirectories = lists.saved
    revertDirectories()
    if status != .usable(droppedEntryCount: 0) {
      await record(
        status.acceptsChanges ? .info : .failure,
        detail: "directory list loaded: \(status.code), \(lists.saved.count) saved")
    }
  } // End of func loadDirectories()

  /// "Save": applies the working copy's edits since `directoryDraftBase` to the saved list as
  /// the store holds it then (`mergeSaved(base:edited:)`, checked and merged by the store under
  /// its lock, so what New session or another muxFinder changed meanwhile is kept; recent
  /// directories untouched) and shows "Saved."; the working copy and `AppModel` take the lists
  /// kept. A failure keeps the working copy, says why, and is logged by its code only; an
  /// unusable file found then makes the tab read-only. Returns whether the list was saved.
  @discardableResult
  public func saveDirectories() async -> Bool {
    guard canSaveDirectories, let store = environment?.directories else { return false }
    let entries = directoryDraft
    let base = directoryDraftBase
    isSavingDirectories = true
    directorySaveError = nil
    directorySaveNotice = nil
    defer { isSavingDirectories = false }
    do throws(DirectoryStoreError) {
      let result = try await store.apply(
        .mergeSaved(base: base, edited: entries), knownHosts: nil)
      savedDirectories = result.lists.saved
      if DirectoryLists.sameEntries(directoryDraft, entries) {
        directoryDraft = result.lists.saved
        directoryDraftBase = result.lists.saved
      } else {
        // Edited while saving: the later edits are relative to what was just merged.
        directoryDraftBase = entries
      }
      directoryStatus = .usable(droppedEntryCount: 0)
      directorySaveNotice = "Saved."
      if let kept = result.displacedFileError { directorySaveError = kept.errorDescription }
      onDirectoriesSaved?(result.lists)
      await record(
        .success,
        detail: "saved directories: \(result.lists.saved.count)"
          + (result.displacedFileError.map { ", displaced file not kept: \($0.code)" } ?? ""))
      return true
    } catch {
      if case .fileNotUsable(let problem) = error { directoryStatus = .fileNotUsable(problem) }
      directorySaveError =
        "muxFinder couldn't save the directories. " + (error.errorDescription ?? "")
      await record(.failure, detail: "saved directories not saved: \(error.code)")
      return false
    }
  } // End of func saveDirectories()

  /// The lists changed outside the tab (New session saved, cleared or recorded a directory):
  /// the list "Revert" brings back follows them, and so do the working copy and its base while
  /// it has no unsaved edits (or the edits made it that list). Otherwise the base stays the
  /// list the edits started from, so "Save" merges them with this change instead of undoing it.
  func directoriesChangedElsewhere(_ lists: DirectoryLists) {
    guard !isPreview, environment?.directories != nil else { return }
    let hadEdits = isDirectoryListDirty
    savedDirectories = lists.saved
    directoryStatus = .usable(droppedEntryCount: 0)
    guard !hadEdits || DirectoryLists.sameEntries(directoryDraft, lists.saved) else { return }
    directoryDraft = lists.saved
    directoryDraftBase = lists.saved
  }
}
