import Foundation
import MuxFinderCore
import os

/// How the app resolves its terminal setting (PLAN.md D38, Phase I-12c3a): where the stored
/// `terminal` is read and written, the terminal definitions, and LaunchServices' answers about
/// the apps. `AppModel` resolves the setting once at launch (`TerminalChoice.resolve`) and again
/// through its one setter (`AppModel.setTerminal(_:)`); there is no file watcher.
public struct TerminalEnvironment: Sendable {
  /// `preferences.json` (`PreferencesStore`, D32's rules): its `terminal` key is read at launch
  /// and written by the setter. `nil` reads and writes nothing: the setting is then absent
  /// (the default applies) and a change is kept in memory only.
  public var preferences: (any TerminalSettingStoring)?
  /// Loads the terminal definitions; called once, at launch (`TerminalDefinitionLoader` over
  /// the bundle's `Resources/Terminals/` and the user's folder, read only, never created).
  /// Their problems are kept for Phase I-12d to show (`AppModel.terminalDefinitions`).
  public var loadDefinitions: @Sendable () -> TerminalDefinitionCatalog
  /// Where LaunchServices finds an app and its version, and whether it runs; read without
  /// launching it or sending an Apple event (`WorkspaceTerminalAppInspector` in the app).
  public var inspector: any TerminalAppInspecting

  /// An environment from its parts.
  public init(
    preferences: (any TerminalSettingStoring)?,
    loadDefinitions: @escaping @Sendable () -> TerminalDefinitionCatalog,
    inspector: any TerminalAppInspecting
  ) {
    self.preferences = preferences
    self.loadDefinitions = loadDefinitions
    self.inspector = inspector
  }

  /// Resolves `stored` (PLAN.md D38, Phase I-12c3a) over `catalog` and LaunchServices' answers
  /// now: whether iTerm2 is installed, and the version check of the candidate definition's app
  /// only (`TerminalChoice.candidateID(stored:iTerm2Installed:)`). Nothing is launched or sent.
  @MainActor
  public func resolve(
    stored: String?,
    catalog: TerminalDefinitionCatalog
  ) -> TerminalChoiceResolution {
    let iTerm2Installed =
      inspector.snapshot(bundleIdentifier: TerminalChoice.iTerm2BundleIdentifier).url != nil
    let candidate = TerminalChoice.candidateID(stored: stored, iTerm2Installed: iTerm2Installed)
    let check = catalog.definition(withID: candidate).map { loaded in
      TerminalAppFacts.versionCheck(
        of: inspector.snapshot(bundleIdentifier: loaded.definition.bundleIdentifier),
        minimum: loaded.definition.minimumVersion)
    }
    return TerminalChoice.resolve(
      stored: stored, iTerm2Installed: iTerm2Installed, definitions: catalog.definitions,
      versionCheck: { _ in check ?? .notInstalled })
  } // End of func resolve(stored:catalog:)
} // End of struct TerminalEnvironment

/// The terminal definitions, loaded once on first use and kept for the app's life (PLAN.md D38,
/// Phase I-12c3a): the terminal setting, the plain backends and This Mac's client attributor all
/// read the same catalog, so the files are read once.
public final class TerminalCatalogCache: Sendable {
  /// Loads the catalog.
  private let loader: @Sendable () -> TerminalDefinitionCatalog
  /// The catalog, once loaded.
  private let state = OSAllocatedUnfairLock<TerminalDefinitionCatalog?>(initialState: nil)

  /// A cache over `loader`; nothing is loaded yet.
  public init(loader: @escaping @Sendable () -> TerminalDefinitionCatalog) {
    self.loader = loader
  }

  /// The catalog, loaded now if it was not yet (two first callers at once may both load; the
  /// first stored wins, so every caller sees one catalog).
  public func catalog() -> TerminalDefinitionCatalog {
    if let cached = state.withLock({ $0 }) { return cached }
    let loaded = loader()
    return state.withLock { stored in
      if let stored { return stored }
      stored = loaded
      return loaded
    }
  } // End of func catalog()
} // End of class TerminalCatalogCache

/// The app's one plain window layer (PLAN.md D38), made at the first plain backend's build: the
/// real `NSAppleScriptRunner`, LaunchServices, the detached spawner and `NSRunningApplication`.
/// Making it compiles, sends and starts nothing.
@MainActor
final class PlainTerminalWindowsHolder {
  /// The layer, made on first use.
  lazy var windows = PlainTerminalWindows(
    runner: NSAppleScriptRunner(), inspector: WorkspaceTerminalAppInspector(),
    spawner: DetachedTerminalProcessSpawner(), activator: RunningApplicationActivator())

  /// A holder with no layer yet.
  init() {}
}
