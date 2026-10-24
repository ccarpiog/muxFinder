import Carbon.HIToolbox
import Foundation
import MuxFinderCore

/// What the current keyboard layout prints for a key (PLAN.md D32): `SystemKeyboardLayout` in
/// the app, `StaticKeyboardLayout` in tests and previews.
@MainActor
public protocol KeyboardLayoutNaming: Sendable {
  /// The character the key with `keyCode` types with no modifier on the current layout, or
  /// `nil` when it types none (or no layout can be read).
  func character(forKeyCode keyCode: UInt16) -> String?
}

/// A fixed table of characters by key code: the tests' fake layout and the previews' layout,
/// so screenshots never depend on the Mac's own. Not tied to the main actor (its conformance
/// is declared in an extension, so it is not inferred), so tables can be built anywhere.
public struct StaticKeyboardLayout: Sendable {
  /// The characters by key code.
  public var characters: [UInt16: String]

  /// A layout typing `characters`.
  public init(characters: [UInt16: String]) {
    self.characters = characters
  }

  /// The character in the table.
  public func character(forKeyCode keyCode: UInt16) -> String? {
    characters[keyCode]
  }

  /// A few keys of the US layout (letters K, J and S, the digits 1 and 3, the comma), enough
  /// for the previews.
  public static let previews = StaticKeyboardLayout(characters: [
    0x28: "k", 0x26: "j", 0x01: "s", 0x12: "1", 0x14: "3", 0x2B: ",",
  ])
}

extension StaticKeyboardLayout: KeyboardLayoutNaming {}

/// The current keyboard layout as macOS reports it: `TISCopyCurrentKeyboardLayoutInputSource`
/// (or the current ASCII-capable layout when that one carries no key layout data, as some input
/// methods do) and `UCKeyTranslate` with no modifier and dead keys not combined, so a dead key
/// shows its own accent. Read on every call, so a layout change shows at the next label.
public struct SystemKeyboardLayout: KeyboardLayoutNaming, Sendable {
  /// The system's layout.
  public init() {}

  /// The character `keyCode` types on the current layout with no modifier.
  public func character(forKeyCode keyCode: UInt16) -> String? {
    guard let data = Self.layoutData() else { return nil }
    let bytes = CFDataGetBytePtr(data)
    return bytes?.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
      var deadKeyState: UInt32 = 0
      var length = 0
      var characters = [UniChar](repeating: 0, count: 8)
      let status = UCKeyTranslate(
        layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, characters.count, &length,
        &characters)
      guard status == noErr, length > 0 else { return nil }
      return String(utf16CodeUnits: characters, count: length)
    }
  } // End of func character(forKeyCode:)

  /// The current layout's `uchr` data, or `nil`.
  static func layoutData() -> CFData? {
    let sources = [
      TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
    ]
    for case let source? in sources {
      guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
      else { continue }
      return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
    }
    return nil
  }
}

/// How a shortcut is shown (PLAN.md D32): the modifier symbols in macOS order (⌃⌥⇧⌘) and the
/// key, as the current layout prints it for typing keys (uppercased, as macOS menus show
/// letters) and by a fixed name or symbol for the others (F1–F20, Space, Return, Tab, Delete,
/// Esc, the arrows and the navigation keys), with a spoken form for VoiceOver.
public struct GlobalShortcutLabel: Sendable, Hashable {
  /// What the recorder shows, such as "⌃⌥K" or "⌘⇧Space".
  public var text: String
  /// What VoiceOver reads, such as "Control-Option-K".
  public var spokenText: String

  /// The symbol and spoken name of each modifier, in macOS order.
  static let modifierNames: [(GlobalShortcut.Modifiers, symbol: String, spoken: String)] = [
    (.control, "⌃", "Control"), (.option, "⌥", "Option"), (.shift, "⇧", "Shift"),
    (.command, "⌘", "Command"),
  ]

  /// Fixed names of keys that type no character (or a blank one): symbol, spoken name.
  static let specialKeys: [UInt16: (symbol: String, spoken: String)] = [
    GlobalShortcut.KeyCode.space: ("Space", "Space"),
    GlobalShortcut.KeyCode.returnKey: ("↩", "Return"),
    GlobalShortcut.KeyCode.tab: ("⇥", "Tab"),
    GlobalShortcut.KeyCode.delete: ("⌫", "Delete"),
    GlobalShortcut.KeyCode.forwardDelete: ("⌦", "Forward delete"),
    GlobalShortcut.KeyCode.escape: ("⎋", "Escape"),
    0x4C: ("⌤", "Enter"),
    0x47: ("⌧", "Clear"),
    0x72: ("Help", "Help"),
    0x73: ("↖", "Home"),
    0x77: ("↘", "End"),
    0x74: ("⇞", "Page up"),
    0x79: ("⇟", "Page down"),
    0x7B: ("←", "Left arrow"),
    0x7C: ("→", "Right arrow"),
    0x7D: ("↓", "Down arrow"),
    0x7E: ("↑", "Up arrow"),
  ]

  /// The label of `shortcut` on `layout`.
  @MainActor
  public init(_ shortcut: GlobalShortcut, layout: any KeyboardLayoutNaming) {
    let modifiers = Self.modifierNames.filter { shortcut.modifiers.contains($0.0) }
    let key = Self.keyName(shortcut.keyCode, layout: layout)
    text = modifiers.map(\.symbol).joined() + key.symbol
    spokenText = (modifiers.map(\.spoken) + [key.spoken]).joined(separator: "-")
  }

  /// The key's symbol and spoken name: a fixed one for F1–F20 and the special keys, else what
  /// the layout types (uppercased; a blank or control character falls back to the key code).
  @MainActor
  static func keyName(
    _ keyCode: UInt16, layout: any KeyboardLayoutNaming
  ) -> (symbol: String, spoken: String) {
    if let number = GlobalShortcut(keyCode: keyCode, modifiers: []).functionKeyNumber {
      return ("F\(number)", "F\(number)")
    }
    if let special = specialKeys[keyCode] { return special }
    if let character = layout.character(forKeyCode: keyCode),
      !character.unicodeScalars.contains(where: {
        $0.properties.generalCategory == .control || $0.properties.isWhitespace
      })
    {
      let shown = character.uppercased()
      return (shown, shown)
    }
    let fallback = "Key \(keyCode)"
    return (fallback, fallback)
  } // End of static func keyName(_:layout:)
}
