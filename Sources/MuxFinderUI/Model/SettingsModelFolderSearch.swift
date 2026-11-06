import Foundation
import MuxFinderCore

/// The Directories tab's folder search setting (PLAN.md D32, D36, Phase I-10b): "Search folders
/// in: Home folder / Whole disk", kept in `preferences.json` through
/// `SettingsEnvironment.preferences` (`PreferencesStore`; never `UserDefaults`), and the
/// "Missing a folder?" explanation's "Open Spotlight settings".
///
/// - **Reading:** when the window opens (and "Try again"); reading never writes. A file that
///   cannot be used reads as `home`: its notice says so, and the choice is off until it is
///   fixed or moved away (the store would refuse every change); a folder that cannot be read
///   too.
/// - **Saving applies at once** (like launch at login; no Save button): picking a scope saves
///   it, and New session reads the scope for each query, so the next one uses it. A failed
///   save brings the previous scope back and says why. The save runs in a task the model owns
///   (`folderSearchScopeSave`), which `shutdown()` waits for, so quitting right after a pick
///   keeps it; the choice is off while it runs, so saves never overlap. Logs carry kinds and
///   codes only.
extension SettingsModel {
  /// Whether "Search folders in" can be changed now: a preferences store (or a fixture, which
  /// shows it on and saves nothing) whose file can be used, no save running, not quitting.
  public var canChangeFolderSearchScope: Bool {
    (isPreview || environment?.preferences != nil) && isFolderSearchScopeFileUsable
      && !isSavingFolderSearchScope && !isShutDown
  }

  /// Reads the scope (the window's opening). Does nothing without a store, after `shutdown()`,
  /// or when the window opened as another generation meanwhile.
  public func loadFolderSearchScope() async {
    guard let store = environment?.preferences, !isShutDown else { return }
    let generation = windowGeneration
    let scope: FolderSearchScope
    let problem: String?
    let code: String?
    do throws(PreferencesStoreError) {
      let result = try await store.load()
      scope = result.preferences.folderSearchScope
      if case .invalid(let file) = result.state {
        problem = Self.unusablePreferencesMessage(file.message)
        code = "fileNotUsable.\(file.code)"
      } else {
        problem = nil
        code = nil
      }
    } catch {
      scope = .standard
      problem =
        "muxFinder couldn't read its settings folder, so folders are searched in the home folder. "
        + (error.errorDescription ?? "")
      code = error.code
    }
    guard windowGeneration == generation, !isShutDown else { return }
    folderSearchScope = scope
    folderSearchScopeProblem = problem
    isFolderSearchScopeFileUsable = code == nil
    if let code { await record(.failure, detail: "folder search scope not read: \(code)") }
  } // End of func loadFolderSearchScope()

  /// "Search folders in" (the picker): shows `scope` at once and saves it in a task the model
  /// owns (`folderSearchScopeSave`), which `shutdown()` waits for; the previous scope comes
  /// back if the save fails (with why). Returns that task (its value: whether it was saved), or
  /// `nil` with nothing changed for the scope shown already, without a store, while a save runs
  /// (the choice is off then, so the scope shown is the one being saved), or after
  /// `shutdown()`.
  @discardableResult
  public func chooseFolderSearchScope(_ scope: FolderSearchScope) -> Task<Bool, Never>? {
    guard canChangeFolderSearchScope, let store = environment?.preferences,
      scope != folderSearchScope
    else { return nil }
    let previous = folderSearchScope
    folderSearchScope = scope
    isSavingFolderSearchScope = true
    let save = Task { () -> Bool in
      let outcome: Result<PreferencesChangeResult, PreferencesStoreError>
      do throws(PreferencesStoreError) {
        outcome = .success(try await store.setFolderSearchScope(scope))
      } catch {
        outcome = .failure(error)
      }
      return await self.folderSearchScopeSaved(scope, previous: previous, outcome: outcome)
    }
    folderSearchScopeSave = save
    return save
  } // End of func chooseFolderSearchScope(_:)

  /// `chooseFolderSearchScope(_:)`, returning once its save has ended: whether `scope` was
  /// saved (`false` when nothing was started).
  @discardableResult
  public func setFolderSearchScope(_ scope: FolderSearchScope) async -> Bool {
    guard let save = chooseFolderSearchScope(scope) else { return false }
    return await save.value
  }

  /// The end of the save of `scope`: the scope saved, or `previous` again with why it was not
  /// (an unusable file turns the choice off); recorded by kind. Returns whether it was saved.
  private func folderSearchScopeSaved(
    _ scope: FolderSearchScope, previous: FolderSearchScope,
    outcome: Result<PreferencesChangeResult, PreferencesStoreError>
  ) async -> Bool {
    defer { isSavingFolderSearchScope = false }
    switch outcome {
    case .success(let result):
      folderSearchScope = result.preferences.folderSearchScope
      folderSearchScopeProblem = nil
      await record(.success, detail: "folder search scope saved: \(scope.rawValue)")
      return true
    case .failure(let error):
      folderSearchScope = previous
      folderSearchScopeProblem =
        "muxFinder couldn't save where folders are searched. " + (error.errorDescription ?? "")
      if case .fileNotUsable = error { isFolderSearchScopeFileUsable = false }
      await record(.failure, detail: "folder search scope not saved: \(error.code)")
      return false
    }
  } // End of func folderSearchScopeSaved(_:previous:outcome:)

  /// What the tab says when the preferences file cannot be used (`problem` the file's).
  nonisolated static func unusablePreferencesMessage(_ problem: String) -> String {
    "muxFinder couldn't use its preferences file, so folders are searched in the home folder. "
      + problem + " Fix it or move it away, then choose Try again."
  }

  /// "Open Spotlight settings" in the explanation: This Mac's Spotlight pane in System
  /// Settings, through `SettingsEnvironment.openURL`. Does nothing for a fixture.
  public func openSpotlightSettings() {
    environment?.openURL(FolderSearchSection.spotlightSettingsURL)
  }
}

extension FolderSearchScope {
  /// The scope's name in Settings › Directories: "Home folder" or "Whole disk".
  public var title: String {
    switch self {
    case .home: return "Home folder"
    case .disk: return "Whole disk"
    }
  }
}
