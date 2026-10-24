import Foundation
import Testing

@testable import MuxFinderCore

/// `GlobalShortcut` (PLAN.md D32): its validation (a modifier besides ⇧ unless F1–F20, the
/// system's own combinations refused, a warning before ⌘ with one key and before only ⌥ or
/// ⌥⇧) and its modifier names.
@Suite("Global shortcut")
struct GlobalShortcutTests {
  /// The K key (`kVK_ANSI_K`).
  static let keyK: UInt16 = 0x28

  /// A shortcut on `keyCode` with `modifiers`.
  static func shortcut(_ keyCode: UInt16, _ modifiers: GlobalShortcut.Modifiers)
    -> GlobalShortcut
  {
    GlobalShortcut(keyCode: keyCode, modifiers: modifiers)
  }

  /// A typing key needs ⌃, ⌥ or ⌘: none, or ⇧ alone, is refused; ⌃, ⌘ with another modifier
  /// and ⌃⌥⇧⌘ are usable.
  @Test func typingKeysNeedAModifierOtherThanShift() {
    #expect(Self.shortcut(Self.keyK, []).check == .refused(.needsModifier))
    #expect(Self.shortcut(Self.keyK, .shift).check == .refused(.needsModifier))
    #expect(
      Self.shortcut(GlobalShortcut.KeyCode.space, .shift).check == .refused(.needsModifier))
    #expect(Self.shortcut(Self.keyK, .control).check == .usable)
    #expect(Self.shortcut(Self.keyK, [.control, .option]).check == .usable)
    #expect(Self.shortcut(Self.keyK, [.command, .shift]).check == .usable)
    #expect(Self.shortcut(Self.keyK, [.control, .option, .shift, .command]).check == .usable)
    #expect(GlobalShortcutRefusal.needsModifier.message.contains("F1 to F20"))
  }

  /// F1–F20 may go alone, or with ⇧; every one of the 20 is recognised.
  @Test func functionKeysMayGoAlone() {
    #expect(GlobalShortcut.KeyCode.functionKeys.count == 20)
    #expect(Set(GlobalShortcut.KeyCode.functionKeys).count == 20)
    for (index, keyCode) in GlobalShortcut.KeyCode.functionKeys.enumerated() {
      #expect(Self.shortcut(keyCode, []).functionKeyNumber == index + 1)
      #expect(Self.shortcut(keyCode, []).check == .usable, "F\(index + 1)")
      #expect(Self.shortcut(keyCode, .shift).check == .usable, "⇧F\(index + 1)")
    }
    #expect(Self.shortcut(GlobalShortcut.KeyCode.f19, []).functionKeyNumber == 19)
    #expect(Self.shortcut(Self.keyK, []).functionKeyNumber == nil)
  }

  /// macOS's own combinations are refused: ⌘Space, ⌘Tab, ⌘⇧Tab, ⌘⇧3/4/5 and ⌘⌥Esc; a
  /// neighbour (⌃⌘Space, ⌘⇧6) is not.
  @Test func refusesTheSystemsOwnCombinations() {
    let code = GlobalShortcut.KeyCode.self
    let refused = [
      Self.shortcut(code.space, .command), Self.shortcut(code.tab, .command),
      Self.shortcut(code.tab, [.command, .shift]), Self.shortcut(code.digit3, [.command, .shift]),
      Self.shortcut(code.digit4, [.command, .shift]),
      Self.shortcut(code.digit5, [.command, .shift]),
      Self.shortcut(code.escape, [.command, .option]),
    ]
    for shortcut in refused {
      #expect(shortcut.check == .refused(.systemShortcut), "\(shortcut)")
      #expect(!shortcut.check.isUsable)
    }
    #expect(Set(refused) == GlobalShortcut.systemShortcuts)
    #expect(Self.shortcut(code.space, [.control, .command]).check == .usable)
    #expect(Self.shortcut(0x16, [.command, .shift]).check == .usable)
    #expect(
      GlobalShortcutRefusal.systemShortcut.message
        == "macOS uses this shortcut itself. Choose another.")
  } // End of func refusesTheSystemsOwnCombinations()

  /// ⌘ with one key is a warning, not a refusal; ⌘ with another modifier is not warned about.
  @Test func warnsBeforeCommandWithOneKey() {
    let warned = Self.shortcut(Self.keyK, .command).check
    #expect(warned == .warning(.commandWithOneKey))
    #expect(warned.isUsable)
    #expect(Self.shortcut(GlobalShortcut.KeyCode.returnKey, .command).check.isUsable)
    #expect(Self.shortcut(Self.keyK, [.command, .option]).check == .usable)
    #expect(
      Self.shortcut(GlobalShortcut.KeyCode.f19, .command).check == .warning(.commandWithOneKey))
  }

  /// Only ⌥ or ⌥⇧ is a warning (macOS 15 and later may not pass the press to apps; Carbon
  /// registers it on macOS 27.2), whatever the key; ⌃⌥ is not.
  @Test func warnsBeforeOnlyOption() {
    for keyCode in [Self.keyK, GlobalShortcut.KeyCode.f19, GlobalShortcut.KeyCode.space] {
      #expect(Self.shortcut(keyCode, .option).check == .warning(.optionOnly))
      #expect(Self.shortcut(keyCode, [.option, .shift]).check == .warning(.optionOnly))
      #expect(Self.shortcut(keyCode, [.option, .shift]).check.isUsable)
    }
    #expect(Self.shortcut(Self.keyK, [.control, .option]).check == .usable)
    #expect(Self.shortcut(Self.keyK, [.option, .command]).check == .usable)
  }

  /// A key code past every keyboard key's is refused.
  @Test func refusesUnknownKeyCodes() {
    #expect(Self.shortcut(GlobalShortcut.maximumKeyCode, .control).check == .usable)
    #expect(
      Self.shortcut(GlobalShortcut.maximumKeyCode + 1, .control).check == .refused(.unknownKey))
    #expect(Self.shortcut(0xFFFF, [.control, .command]).check == .refused(.unknownKey))
  }

  /// Modifier names come in macOS order (⌃⌥⇧⌘); names read back in any order, repeats
  /// allowed; an unknown name is refused.
  @Test func modifierNamesRoundTrip() {
    let all: GlobalShortcut.Modifiers = [.command, .shift, .option, .control]
    #expect(all.names == ["control", "option", "shift", "command"])
    #expect(
      GlobalShortcut.Modifiers(names: ["command", "control", "command"]) == [.control, .command])
    #expect(GlobalShortcut.Modifiers(names: []) == [])
    #expect(GlobalShortcut.Modifiers(names: ["control", "fn"]) == nil)
    #expect(GlobalShortcut.Modifiers(names: ["Control"]) == nil)
    for raw in UInt8(0)...15 {
      let modifiers = GlobalShortcut.Modifiers(rawValue: raw)
      #expect(GlobalShortcut.Modifiers(names: modifiers.names) == modifiers)
    }
  } // End of func modifierNamesRoundTrip()
}
