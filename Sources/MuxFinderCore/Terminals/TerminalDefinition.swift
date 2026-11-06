import Foundation

/// A terminal app muxFinder can open plain tmux attaches in, described by a small JSON file
/// (PLAN.md D38, Phase I-12b1): its identity, how a window running the launch helper is opened,
/// how that window is brought forward, and whether the helper keeps its minimum lifetime.
/// iTerm2 has no definition: it is code. Built-in definitions ship in the app bundle; user
/// definitions in `~/Library/Application Support/muxFinder/terminals/` add terminals or
/// override a built-in one by id (`TerminalDefinitionLoader`).
///
/// A definition can only be made by `TerminalDefinition.decode(_:)`, which checks every field
/// (`TerminalDefinitionProblem` lists the refusals), so every value held here is valid.
public struct TerminalDefinition: Sendable, Hashable {
  /// The only schema version this muxFinder reads.
  public static let schemaVersion = 1
  /// Ids no definition may take: iTerm2 is code, not a definition.
  public static let reservedIDs: Set<String> = ["iterm2"]

  /// A short stable id: `[a-z0-9-]`, 1–32 bytes.
  public let id: String
  /// The name shown to the user: 1–64 characters, no control character.
  public let displayName: String
  /// The bundle identifier LaunchServices finds the app by.
  public let bundleIdentifier: String
  /// The oldest version of the app that works with this definition.
  public let minimumVersion: TerminalVersion
  /// A short note for the user (at most 1 KiB), if any.
  public let notes: String?
  /// How a window running the launch helper is opened.
  public let open: TerminalOpenMethod
  /// How that window is brought forward.
  public let focus: TerminalFocusKind
  /// Whether the launch helper keeps its 10 s minimum lifetime in this terminal.
  public let keepsMinimumLifetime: Bool

  /// A definition made of already checked values (the parser's and tests' initializer).
  init(
    id: String,
    displayName: String,
    bundleIdentifier: String,
    minimumVersion: TerminalVersion,
    notes: String?,
    open: TerminalOpenMethod,
    focus: TerminalFocusKind,
    keepsMinimumLifetime: Bool
  ) {
    self.id = id
    self.displayName = displayName
    self.bundleIdentifier = bundleIdentifier
    self.minimumVersion = minimumVersion
    self.notes = notes
    self.open = open
    self.focus = focus
    self.keepsMinimumLifetime = keepsMinimumLifetime
  } // End of init(id:displayName:bundleIdentifier:minimumVersion:notes:open:focus:…)

  /// Whether opening or focusing through this definition sends Apple events, and so needs the
  /// Automation permission for its app: only `appleScript` definitions do.
  public var needsAutomationPermission: Bool {
    if case .appleScript = open { return true }
    return false
  }
} // End of struct TerminalDefinition

/// How a definition opens a window running the launch helper.
public enum TerminalOpenMethod: Sendable, Hashable {
  /// A static AppleScript file in the definition's own folder, compiled once and called
  /// through the fixed handlers (`TerminalScriptHandler`), with the launch command in the
  /// given form. `script` is a plain file name.
  case appleScript(script: String, command: TerminalCommandForm)
  /// A program spawned with an argv, never through a shell: `executable` is a path relative
  /// to the app LaunchServices finds (no leading `/`, no `..`), and every argument is literal
  /// or exactly one whole placeholder.
  case exec(executable: String, arguments: [TerminalExecArgument])

  /// The JSON `kind`: `appleScript` or `exec`.
  public var kind: String {
    switch self {
    case .appleScript: return "appleScript"
    case .exec: return "exec"
    }
  }

  /// The command form of an `appleScript` open; `nil` for `exec`.
  public var commandForm: TerminalCommandForm? {
    if case .appleScript(_, let form) = self { return form }
    return nil
  }
} // End of enum TerminalOpenMethod

/// Which form of the launch command an AppleScript open receives (PLAN.md D38).
public enum TerminalCommandForm: String, Sendable, Hashable, CaseIterable {
  /// One shell command text, D3's extension (`TerminalCommandText`), for a terminal that types
  /// it into the user's shell, such as Terminal's `do script`.
  case shellText
  /// The helper path, the mode word and the token as separate values, each limited to
  /// `TerminalLaunchCommand.wordBytes`, so a terminal's own command parsing (Ghostty's
  /// `command`) reads them the same however it parses.
  case words
}

/// How muxFinder brings a launch's window forward (PLAN.md D38).
public enum TerminalFocusKind: String, Sendable, Hashable, CaseIterable {
  /// By the launch's terminal device: the window whose tab has it (Terminal). Needs an
  /// `appleScript` open.
  case tty
  /// By the window id the open returned (Ghostty). Needs an `appleScript` open.
  case windowID
  /// Only the app is brought forward.
  case app
}

/// A placeholder an `exec` argument may be, as a whole argument.
public enum TerminalPlaceholder: String, Sendable, Hashable, CaseIterable {
  /// The launch helper's absolute path.
  case helper
  /// The helper's constant mode word.
  case mode
  /// The launch token (a canonical UUID).
  case token

  /// The placeholder as written in a definition, such as `{helper}`.
  public var text: String { "{\(rawValue)}" }
}

/// One argument of an `exec` definition.
public enum TerminalExecArgument: Sendable, Hashable {
  /// Passed as written.
  case literal(String)
  /// Replaced by its value when the argv is built.
  case placeholder(TerminalPlaceholder)
}

/// A dotted decimal version, such as `1.3` or `2.15.1`, compared numerically component by
/// component; missing components count as zero, so `1.3` equals `1.3.0`.
public struct TerminalVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
  /// The most components a version may have.
  static let maximumComponents = 8
  /// The most digits one component may have (so it always fits an `Int`).
  static let maximumComponentDigits = 9

  /// The numbers, in order.
  public let components: [Int]
  /// The text the version was read from.
  public let text: String

  /// Reads `text`: one or more groups of 1–9 ASCII digits separated by single dots, at most
  /// 8 groups. Anything else (letters, a suffix such as `-beta`, spaces) is `nil`.
  public init?(_ text: String) {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard !parts.isEmpty, parts.count <= Self.maximumComponents else { return nil }
    var numbers: [Int] = []
    for part in parts {
      guard !part.isEmpty, part.utf8.count <= Self.maximumComponentDigits,
        part.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let number = Int(part)
      else { return nil }
      numbers.append(number)
    } // End of loop over the version's components
    components = numbers
    self.text = text
  } // End of init?(_:)

  /// The components without trailing zeros, so equal versions compare and hash the same.
  var significant: ArraySlice<Int> {
    var end = components.count
    while end > 0, components[end - 1] == 0 { end -= 1 }
    return components[0..<end]
  }

  /// The text the version was read from.
  public var description: String { text }

  /// Numeric equality, ignoring trailing zero components.
  public static func == (lhs: TerminalVersion, rhs: TerminalVersion) -> Bool {
    lhs.significant == rhs.significant
  }

  /// Hashes the significant components, matching `==`.
  public func hash(into hasher: inout Hasher) {
    hasher.combine(Array(significant))
  }

  /// Numeric order, component by component, missing components counting as zero.
  public static func < (lhs: TerminalVersion, rhs: TerminalVersion) -> Bool {
    let count = max(lhs.components.count, rhs.components.count)
    for index in 0..<count {
      let left = index < lhs.components.count ? lhs.components[index] : 0
      let right = index < rhs.components.count ? rhs.components[index] : 0
      if left != right { return left < right }
    }
    return false
  }

  /// Whether `installed` (an app's `CFBundleShortVersionString`) meets `minimum`: `true` or
  /// `false` when it reads as a version, `nil` ("unknown", never a pass) when it is missing or
  /// does not read as one.
  public static func meets(installed: String?, minimum: TerminalVersion) -> Bool? {
    guard let installed, let version = TerminalVersion(installed) else { return nil }
    return version >= minimum
  }
} // End of struct TerminalVersion
