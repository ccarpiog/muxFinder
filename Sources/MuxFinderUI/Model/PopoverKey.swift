import AppKit

/// The popover's keyboard commands (PLAN.md Phase 8, D31): ↑/↓ move, Return opens, ⌘F search,
/// ⌘R refresh, ⌘N new session, ⌘, settings, Esc closes, and ⌥↓ opens New session's directory
/// list.
public enum PopoverKey: Sendable, Hashable, CaseIterable {
  /// ↑: the previous session row (or, in New session's open directory list, the previous row).
  case up
  /// ↓: the next session row (or, in New session's open directory list, the next row).
  case down
  /// Return (or the keypad's Enter): open the selected session.
  case open
  /// Esc: close the popover.
  case close
  /// ⌘F: put the cursor in the search field.
  case find
  /// ⌘R: refresh every host.
  case refresh
  /// ⌘N: new session.
  case newSession
  /// ⌘,: settings.
  case settings
  /// ⌥↓: open New session's directory list (PLAN.md D31); elsewhere the key goes on to the
  /// focused view, as before.
  case openList

  /// The virtual key codes used (Carbon's `kVK_…` values).
  enum KeyCode {
    /// `kVK_UpArrow`.
    static let upArrow: UInt16 = 126
    /// `kVK_DownArrow`.
    static let downArrow: UInt16 = 125
    /// `kVK_Return`.
    static let returnKey: UInt16 = 36
    /// `kVK_ANSI_KeypadEnter`.
    static let keypadEnter: UInt16 = 76
    /// `kVK_Escape`.
    static let escape: UInt16 = 53
  }

  /// The command for a key press, or `nil` when the popover leaves it to the focused view.
  /// Arrows, Return and Esc count only without modifiers (the arrows' own `numericPad` and
  /// `function` flags aside), ↓ also with ⌥ alone (`openList`); the letters and the comma only
  /// with ⌘ alone.
  public init?(
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    charactersIgnoringModifiers: String?
  ) {
    let modifiers = modifierFlags.intersection([.command, .option, .control, .shift])
    if modifiers == .command {
      switch charactersIgnoringModifiers?.lowercased() {
      case "f": self = .find
      case "r": self = .refresh
      case "n": self = .newSession
      case ",": self = .settings
      default: return nil
      }
      return
    }
    if modifiers == .option {
      guard keyCode == KeyCode.downArrow else { return nil }
      self = .openList
      return
    }
    guard modifiers.isEmpty else { return nil }
    switch keyCode {
    case KeyCode.upArrow: self = .up
    case KeyCode.downArrow: self = .down
    case KeyCode.returnKey, KeyCode.keypadEnter: self = .open
    case KeyCode.escape: self = .close
    default: return nil
    }
  } // End of init?(keyCode:modifierFlags:charactersIgnoringModifiers:)
}

/// What the popover window does after the model handled a key.
public enum PopoverKeyResult: Sendable, Hashable {
  /// The key was used; it goes no further.
  case handled
  /// The popover should close (Esc).
  case closePopover
  /// The model did not use the key (⌥↓ outside New session); it goes on to the focused view.
  case ignored
}
