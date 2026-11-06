import Foundation
import MuxFinderCore

/// The one source of terminal wording in the UI (PLAN.md D38, Phase I-12d1): the chosen
/// terminal's display name ("iTerm2", "Terminal", "Ghostty", a user definition's `name`), the
/// place a session opens in ("tab" in iTerm2, "window" otherwise) and the strings built from
/// them. Sentence case, English. With iTerm2 every string is exactly today's (requirement 12).
public struct TerminalWording: Sendable, Hashable {
  /// Which terminal app the wording is about, where a string depends on more than its name
  /// (where to paste the persistent work command).
  public enum Kind: String, Sendable, Hashable {
    /// iTerm2 (native control mode).
    case iTerm2
    /// macOS's Terminal (`com.apple.Terminal`).
    case terminalApp
    /// Ghostty (`com.mitchellh.ghostty`).
    case ghostty
    /// Any other terminal, or one muxFinder has no definition for.
    case other
  }

  /// Terminal.app's bundle identifier.
  static let terminalAppBundleIdentifier = "com.apple.terminal"
  /// Ghostty's bundle identifier.
  static let ghosttyBundleIdentifier = "com.mitchellh.ghostty"
  /// The name used for a stored terminal id no loaded definition has.
  public static let unknownTerminalName = "the chosen terminal"

  /// iTerm2's wording: every string as it was before other terminals (requirement 12).
  public static let iTerm2 = TerminalWording(name: "iTerm2", kind: .iTerm2)

  /// The terminal's display name.
  public let name: String
  /// Which terminal app it is.
  public let kind: Kind

  /// A wording for `name` of `kind`.
  public init(name: String, kind: Kind) {
    self.name = name
    self.kind = kind
  }

  /// The wording of a plain definition: its display name, and its kind by bundle identifier
  /// (compared without regard to case, as LaunchServices does).
  public init(definition: TerminalDefinition) {
    let identifier = definition.bundleIdentifier.lowercased()
    let kind: Kind
    switch identifier {
    case Self.terminalAppBundleIdentifier: kind = .terminalApp
    case Self.ghosttyBundleIdentifier: kind = .ghostty
    default: kind = .other
    }
    self.init(name: definition.displayName, kind: kind)
  }

  /// The wording of `resolution` (`catalog` names an unavailable choice's definition): iTerm2's
  /// for iTerm2 and while the choice is not resolved yet (today's strings); a plain
  /// definition's for a plain choice; for an unavailable one, its definition's when loaded,
  /// iTerm2's for `iterm2`, else `unknownTerminalName`.
  public init(_ resolution: TerminalChoiceResolution, catalog: TerminalDefinitionCatalog?) {
    switch resolution {
    case .iTerm2, .unresolved:
      self = .iTerm2
    case .plain(let loaded):
      self.init(definition: loaded.definition)
    case .unavailable(let failure):
      if failure.terminalID == TerminalChoice.iTerm2ID {
        self = .iTerm2
      } else if let loaded = catalog?.definition(withID: failure.terminalID) {
        self.init(definition: loaded.definition)
      } else {
        self.init(name: Self.unknownTerminalName, kind: .other)
      }
    }
  } // End of init(_:catalog:)

  /// Whether this is iTerm2's wording.
  public var isITerm2: Bool { kind == .iTerm2 }

  /// Where a session opens: "tab" in iTerm2, "window" otherwise.
  public var place: String { isITerm2 ? "tab" : "window" }

  // MARK: - Set up SSH (PLAN.md D24)

  /// "Set up SSH in iTerm2…", "Set up SSH in Terminal…".
  public var setUpSSHTitle: String { "Set up SSH in \(name)…" }

  /// "Set up SSH in iTerm2 first", offered under a sign-in or host key problem.
  public var setUpSSHFirstTitle: String { "Set up SSH in \(name) first" }

  /// The button's help text.
  public var setUpSSHHelp: String {
    "Open a new \(name) window running ssh to this destination, so you can sign in or accept "
      + "its host key"
  }

  /// The line while the window is being opened.
  public var sshSetupOpening: String { "Opening a new \(name) window…" }

  /// The line once the window opened.
  public var sshSetupOpened: String {
    "\(name) opened a new window running ssh to this host. Sign in or answer the host key "
      + "question there, then check the host again."
  }

  /// The start of a failure's line.
  public var sshSetupFailedPrefix: String { "muxFinder couldn't open ssh in \(name). " }

  // MARK: - Settings and onboarding

  /// "Not used with Terminal": what iTerm2's rows read with a plain choice (Diagnostics).
  public var notUsedWith: String { "Not used with \(name)" }

  /// The permission line onboarding shows for an AppleScript terminal (PLAN.md D38).
  public var permissionLine: String {
    "macOS asks once, the first time muxFinder opens a \(name) window. Allow it; you can change "
      + "it later in System Settings › Privacy & Security › Automation."
  }

  /// The introduction onboarding shows under its title.
  public var introduction: String {
    "muxFinder finds the tmux sessions on your Macs and opens them in \(name)."
  }
} // End of struct TerminalWording
