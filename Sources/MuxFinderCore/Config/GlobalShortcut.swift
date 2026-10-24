import Foundation

/// A system-wide keyboard shortcut (PLAN.md D32): a virtual key code, the key's position on the
/// keyboard whatever the layout (Carbon's `kVK_…` numbering, the same as `NSEvent.keyCode`),
/// and the modifiers held with it. muxFinder stores the key code, never a character, so a
/// shortcut keeps working when the keyboard layout changes; its label is worked out from the
/// current layout when shown (`GlobalShortcutLabel` in MuxFinderUI).
public struct GlobalShortcut: Sendable, Hashable, CustomStringConvertible {
  /// The modifier keys held with the key.
  public struct Modifiers: OptionSet, Sendable, Hashable {
    /// The bits.
    public let rawValue: UInt8

    /// Modifiers from their bits.
    public init(rawValue: UInt8) {
      self.rawValue = rawValue
    }

    /// ⌃ Control.
    public static let control = Modifiers(rawValue: 1 << 0)
    /// ⌥ Option.
    public static let option = Modifiers(rawValue: 1 << 1)
    /// ⇧ Shift.
    public static let shift = Modifiers(rawValue: 1 << 2)
    /// ⌘ Command.
    public static let command = Modifiers(rawValue: 1 << 3)

    /// Each modifier in macOS order (⌃⌥⇧⌘) with its name in `preferences.json`.
    public static let ordered: [(modifier: Modifiers, name: String)] = [
      (.control, "control"), (.option, "option"), (.shift, "shift"), (.command, "command"),
    ]

    /// The modifiers' names in macOS order, as `preferences.json` holds them.
    public var names: [String] {
      Self.ordered.filter { contains($0.modifier) }.map(\.name)
    }

    /// The modifiers named in `names` (any order, repeats allowed); `nil` when one is not a
    /// modifier's name.
    public init?(names: [String]) {
      var modifiers = Modifiers()
      for name in names {
        guard let entry = Self.ordered.first(where: { $0.name == name }) else { return nil }
        modifiers.insert(entry.modifier)
      }
      self = modifiers
    }
  } // End of struct Modifiers

  /// Virtual key codes muxFinder names or checks (Carbon's `kVK_…` values).
  public enum KeyCode {
    /// The digit 3 key of the main block (`kVK_ANSI_3`).
    public static let digit3: UInt16 = 0x14
    /// The digit 4 key (`kVK_ANSI_4`).
    public static let digit4: UInt16 = 0x15
    /// The digit 5 key (`kVK_ANSI_5`).
    public static let digit5: UInt16 = 0x17
    /// The J key (`kVK_ANSI_J`).
    public static let letterJ: UInt16 = 0x26
    /// Return (`kVK_Return`).
    public static let returnKey: UInt16 = 0x24
    /// Tab (`kVK_Tab`).
    public static let tab: UInt16 = 0x30
    /// Space (`kVK_Space`).
    public static let space: UInt16 = 0x31
    /// Delete, the backspace key (`kVK_Delete`).
    public static let delete: UInt16 = 0x33
    /// Escape (`kVK_Escape`).
    public static let escape: UInt16 = 0x35
    /// Forward delete (`kVK_ForwardDelete`).
    public static let forwardDelete: UInt16 = 0x75
    /// F1 to F20, in order (`kVK_F1` … `kVK_F20`).
    public static let functionKeys: [UInt16] = [
      0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
      0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
    ]
    /// F19 (`kVK_F19`), the key of the registration diagnostic's test combinations.
    public static let f19: UInt16 = 0x50
  }

  /// The largest key code a shortcut takes: every virtual key code macOS defines is below 128.
  public static let maximumKeyCode: UInt16 = 0x7F

  /// The key's virtual key code.
  public var keyCode: UInt16
  /// The modifiers held with it.
  public var modifiers: Modifiers

  /// A shortcut from its key code and modifiers (not checked; see `check`).
  public init(keyCode: UInt16, modifiers: Modifiers) {
    self.keyCode = keyCode
    self.modifiers = modifiers
  }

  /// The number of the function key (1 for F1 … 20 for F20), or `nil` for any other key.
  public var functionKeyNumber: Int? {
    KeyCode.functionKeys.firstIndex(of: keyCode).map { $0 + 1 }
  }

  /// Key code and modifier names, for logs and tests (never shown to the user).
  public var description: String {
    "keyCode \(keyCode) [\(modifiers.names.joined(separator: ", "))]"
  }

  /// The combinations macOS keeps for itself, refused outright: Spotlight (⌘Space), the app
  /// switcher (⌘Tab, ⌘⇧Tab), the screenshots (⌘⇧3, ⌘⇧4, ⌘⇧5) and Force Quit (⌘⌥Esc).
  public static let systemShortcuts: Set<GlobalShortcut> = [
    GlobalShortcut(keyCode: KeyCode.space, modifiers: .command),
    GlobalShortcut(keyCode: KeyCode.tab, modifiers: .command),
    GlobalShortcut(keyCode: KeyCode.tab, modifiers: [.command, .shift]),
    GlobalShortcut(keyCode: KeyCode.digit3, modifiers: [.command, .shift]),
    GlobalShortcut(keyCode: KeyCode.digit4, modifiers: [.command, .shift]),
    GlobalShortcut(keyCode: KeyCode.digit5, modifiers: [.command, .shift]),
    GlobalShortcut(keyCode: KeyCode.escape, modifiers: [.command, .option]),
  ]

  /// Whether the shortcut can be used, and whether the recorder should warn first (PLAN.md D32):
  /// - refused: a key code over `maximumKeyCode`; no modifier but ⇧ (or none) unless the key is
  ///   F1–F20; one of `systemShortcuts`;
  /// - a warning, not a refusal: ⌘ and nothing else with the key, which would take that key's
  ///   ⌘ shortcut away from every app; only ⌥ or ⌥⇧ as modifiers, which macOS 15 and later is
  ///   reported to ignore for apps. On macOS 27.2 Carbon registers such a combination without
  ///   an error (`--report-hotkey-registration`), so whether a press arrives is a check by
  ///   hand, and the refusal is not made;
  /// - otherwise usable.
  public var check: GlobalShortcutCheck {
    guard keyCode <= Self.maximumKeyCode else { return .refused(.unknownKey) }
    let essential = modifiers.subtracting(.shift)
    if essential.isEmpty, functionKeyNumber == nil { return .refused(.needsModifier) }
    if Self.systemShortcuts.contains(self) { return .refused(.systemShortcut) }
    if modifiers == .option || modifiers == [.option, .shift] { return .warning(.optionOnly) }
    if modifiers == .command { return .warning(.commandWithOneKey) }
    return .usable
  } // End of var check
}

/// Why a shortcut cannot be used (PLAN.md D32). The messages use the modifier symbols, never a
/// key the user typed.
public enum GlobalShortcutRefusal: String, Sendable, Hashable, Error {
  /// No modifier other than ⇧, on a key other than F1–F20.
  case needsModifier
  /// A combination macOS uses itself.
  case systemShortcut
  /// A key code no keyboard key has.
  case unknownKey

  /// The user-facing explanation, in English and sentence case.
  public var message: String {
    switch self {
    case .needsModifier:
      return "Add ⌃, ⌥ or ⌘ to the shortcut. Only F1 to F20 work on their own."
    case .systemShortcut:
      return "macOS uses this shortcut itself. Choose another."
    case .unknownKey:
      return "muxFinder can't use this key in a shortcut. Choose another."
    }
  } // End of var message
}

/// What the recorder warns about before it takes a shortcut (PLAN.md D32).
public enum GlobalShortcutWarning: String, Sendable, Hashable {
  /// ⌘ and one key: that key's ⌘ shortcut would stop working in every app.
  case commandWithOneKey
  /// Only ⌥ or ⌥⇧: macOS 15 and later may not pass the press to apps.
  case optionOnly
}

/// The outcome of `GlobalShortcut.check`.
public enum GlobalShortcutCheck: Sendable, Hashable {
  /// The shortcut can be used.
  case usable
  /// The shortcut can be used once the user confirms the warning.
  case warning(GlobalShortcutWarning)
  /// The shortcut cannot be used.
  case refused(GlobalShortcutRefusal)

  /// Whether the shortcut may be stored and registered (a warning included).
  public var isUsable: Bool {
    if case .refused = self { return false }
    return true
  }
}
