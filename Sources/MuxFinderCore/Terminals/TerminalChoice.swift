import Foundation

/// A terminal choice that can be used (PLAN.md D38, Phase I-12c3a): iTerm2, or a loaded plain
/// definition. The app builds one `TerminalBackend` per chosen terminal
/// (`AppEnvironment.makeTerminalBackend`) and keeps it for its life.
public enum ChosenTerminal: Sendable, Hashable {
  /// iTerm2 (native control mode, `ITerm2TerminalBackend` over the attach coordinator).
  case iTerm2
  /// The terminal app of this loaded definition (plain mode, `PlainTerminalBackend`).
  case plain(LoadedTerminalDefinition)

  /// The terminal id: `iterm2`, or the definition's id. Backends are cached by it.
  public var id: String {
    switch self {
    case .iTerm2: return TerminalChoice.iTerm2ID
    case .plain(let loaded): return loaded.definition.id
    }
  }

  /// The terminal app launch requests name.
  public var terminal: LaunchTerminalApp {
    switch self {
    case .iTerm2: return .iterm2
    case .plain(let loaded): return .plain(definitionID: loaded.definition.id)
    }
  }

  /// Whether this is iTerm2, the only terminal whose API the app contacts.
  public var usesITerm2: Bool { self == .iTerm2 }
} // End of enum ChosenTerminal

/// Why the terminal choice cannot be used (PLAN.md D38, Phase I-12c3a; requirement 8): the
/// choice is never silently replaced by another terminal, so every session action ends in this
/// failure with nothing written, launched or sent. Names the choice and the reason; no user
/// data (a terminal id is a definition's, or `iterm2`).
public struct TerminalChoiceUnavailable: Error, Sendable, Hashable {
  /// Why the chosen terminal cannot be used.
  public enum Reason: Sendable, Hashable {
    /// No loaded definition has the id (a typo, a removed user definition, a definition file
    /// that could not be used, or a stored value that is not a terminal id at all).
    case unknownID
    /// LaunchServices finds no app with the terminal's bundle identifier (for `iterm2`:
    /// iTerm2 is not installed).
    case notInstalled
    /// The installed app is older than the definition's minimum version.
    case versionTooOld(minimum: TerminalVersion)
    /// The installed app's version is missing or unreadable, so it cannot be checked against
    /// the definition's minimum (never a pass, as for the window layer's open).
    case versionUnknown(minimum: TerminalVersion)

    /// A stable name: `unknownID`, `notInstalled`, `versionTooOld` or `versionUnknown`.
    public var kind: String {
      switch self {
      case .unknownID: return "unknownID"
      case .notInstalled: return "notInstalled"
      case .versionTooOld: return "versionTooOld"
      case .versionUnknown: return "versionUnknown"
      }
    }
  } // End of enum Reason

  /// The terminal id the choice names (as stored, or the default's).
  public let terminalID: String
  /// Why it cannot be used.
  public let reason: Reason

  /// A failure for `terminalID` with `reason`.
  public init(terminalID: String, reason: Reason) {
    self.terminalID = terminalID
    self.reason = reason
  }

  /// A short machine-readable name, such as `notInstalled`.
  public var kind: String { reason.kind }

  /// A neutral explanation (Phase I-12d writes the app's own sentence and the picker).
  public var message: String {
    let name = TerminalChoice.displayID(terminalID)
    switch reason {
    case .unknownID:
      return "muxFinder doesn't know the terminal \(name) chosen in its settings, so nothing "
        + "was opened."
    case .notInstalled:
      return "The terminal \(name) chosen in muxFinder's settings isn't installed, so nothing "
        + "was opened."
    case .versionTooOld(let minimum):
      return "The terminal \(name) chosen in muxFinder's settings is older than version "
        + "\(minimum.text), so nothing was opened."
    case .versionUnknown:
      return "muxFinder couldn't read the version of the terminal \(name) chosen in its "
        + "settings, so nothing was opened."
    }
  } // End of var message
} // End of struct TerminalChoiceUnavailable

/// How the terminal setting resolved (PLAN.md D38, Phase I-12c3a): iTerm2, a plain definition,
/// unavailable with the reason, or not resolved yet.
public enum TerminalChoiceResolution: Sendable, Hashable {
  /// iTerm2.
  case iTerm2
  /// The terminal app of this loaded definition.
  case plain(LoadedTerminalDefinition)
  /// The choice cannot be used now; nothing is replaced for it.
  case unavailable(TerminalChoiceUnavailable)
  /// The setting has not been resolved yet: the app's state from its creation until launch
  /// has loaded the definitions and read the stored value (Phase I-12c3a review fix). It
  /// behaves like a choice that is not iTerm2 (`usesITerm2` is false, nothing is chosen), so
  /// nothing contacts iTerm2 before the stored choice is known. `TerminalChoice.resolve` never
  /// returns it.
  case unresolved

  /// The usable choice, or `nil` when unavailable or not resolved yet.
  public var chosen: ChosenTerminal? {
    switch self {
    case .iTerm2: return .iTerm2
    case .plain(let loaded): return .plain(loaded)
    case .unavailable, .unresolved: return nil
    }
  }

  /// Whether iTerm2 is the choice: only then does the app contact iTerm2 (requirement 7). Not
  /// while the choice is not resolved yet.
  public var usesITerm2: Bool { self == .iTerm2 }

  /// The terminal id the choice names: `iterm2`, a definition's id, the unavailable one's, or
  /// empty while not resolved yet.
  public var terminalID: String {
    switch self {
    case .iTerm2: return TerminalChoice.iTerm2ID
    case .plain(let loaded): return loaded.definition.id
    case .unavailable(let failure): return failure.terminalID
    case .unresolved: return ""
    }
  }

  /// A short machine-readable name: `iterm2`, `plain`, `unavailable` or `unresolved`.
  public var kind: String {
    switch self {
    case .iTerm2: return TerminalChoice.iTerm2ID
    case .plain: return "plain"
    case .unavailable: return "unavailable"
    case .unresolved: return "unresolved"
    }
  }
} // End of enum TerminalChoiceResolution

/// The terminal setting's resolution (PLAN.md D38, Phase I-12c3a): typed and pure over its
/// inputs, the stored value, whether iTerm2 is installed, the loaded definitions and their apps'
/// version checks.
///
/// - **Absent** (`nil`): the default, never written: iTerm2 when it is installed, otherwise the
///   built-in Terminal definition (`fallbackID`), resolved like a stored one.
/// - **`iterm2`**: iTerm2 when installed, else `unavailable(notInstalled)`; a stored `iterm2`
///   is never replaced by Terminal when iTerm2 is gone.
/// - **A definition id**: the loaded definition with that id when its app is installed and its
///   version meets the definition's minimum; else unavailable (`unknownID`, `notInstalled`,
///   `versionTooOld`, `versionUnknown`). Nothing is ever replaced for an unavailable choice
///   (requirement 8).
public enum TerminalChoice {
  /// The id of iTerm2, which has no definition (it is code).
  public static let iTerm2ID = LaunchTerminalApp.iterm2Value
  /// iTerm2's bundle identifier, as LaunchServices finds it.
  public static let iTerm2BundleIdentifier = LocalTerminalApp.iTerm2BundleIdentifier
  /// The default when iTerm2 is not installed: the built-in Terminal definition's id.
  public static let fallbackID = "terminal"
  /// The longest id shown in a message; a longer stored value is cut there.
  static let maximumDisplayedIDLength = 32

  /// The terminal id the resolution looks at: `stored` when set, else `iterm2` when iTerm2 is
  /// installed, else `fallbackID`. Production reads only that definition's app facts.
  public static func candidateID(stored: String?, iTerm2Installed: Bool) -> String {
    if let stored { return stored }
    return iTerm2Installed ? iTerm2ID : fallbackID
  }

  /// Resolves the setting. `versionCheck` gives the version check of a definition's app
  /// (`TerminalAppFacts.versionCheck(of:minimum:)` over LaunchServices in production); it is
  /// asked for the candidate's definition only.
  public static func resolve(
    stored: String?,
    iTerm2Installed: Bool,
    definitions: [LoadedTerminalDefinition],
    versionCheck: (LoadedTerminalDefinition) -> TerminalAppFacts.VersionCheck
  ) -> TerminalChoiceResolution {
    let id = candidateID(stored: stored, iTerm2Installed: iTerm2Installed)
    if id == iTerm2ID {
      guard iTerm2Installed else {
        return .unavailable(TerminalChoiceUnavailable(terminalID: id, reason: .notInstalled))
      }
      return .iTerm2
    }
    guard let loaded = definitions.first(where: { $0.definition.id == id }) else {
      return .unavailable(TerminalChoiceUnavailable(terminalID: id, reason: .unknownID))
    }
    let minimum = loaded.definition.minimumVersion
    switch versionCheck(loaded) {
    case .meets:
      return .plain(loaded)
    case .notInstalled:
      return .unavailable(TerminalChoiceUnavailable(terminalID: id, reason: .notInstalled))
    case .tooOld:
      return .unavailable(
        TerminalChoiceUnavailable(terminalID: id, reason: .versionTooOld(minimum: minimum)))
    case .unknown:
      return .unavailable(
        TerminalChoiceUnavailable(terminalID: id, reason: .versionUnknown(minimum: minimum)))
    }
  } // End of static func resolve(stored:iTerm2Installed:definitions:versionCheck:)

  /// `id` as a message shows it: quoted, printable ASCII only (anything else is `?`), at most
  /// `maximumDisplayedIDLength` characters.
  static func displayID(_ id: String) -> String {
    var shown = ""
    for scalar in id.unicodeScalars.prefix(maximumDisplayedIDLength) {
      shown.unicodeScalars.append((0x20...0x7E).contains(scalar.value) ? scalar : "?")
    }
    if id.unicodeScalars.count > maximumDisplayedIDLength { shown += "…" }
    return "“\(shown)”"
  } // End of static func displayID(_:)
} // End of enum TerminalChoice
