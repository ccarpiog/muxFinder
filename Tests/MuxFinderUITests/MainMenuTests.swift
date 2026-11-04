import AppKit
import Testing

@testable import MuxFinderUI

/// The menu bar app's hand-built main menu (PLAN.md D33): its three menus, each item's title,
/// key equivalent, modifier mask and action, every command going to the first responder, and
/// no Settings item. Builds menus only: nothing is installed in the test process's
/// application and no window is shown.
@Suite("Main menu")
@MainActor
struct MainMenuTests {
  /// What a test expects of one item: a separator, a submenu, or a command.
  enum Expected: Equatable {
    /// A separator.
    case separator
    /// An item opening a submenu titled like the item.
    case submenu(String)
    /// A command: title, key equivalent, modifiers and action.
    case command(String, key: String, modifiers: NSEvent.ModifierFlags, action: String)
  }

  /// The items of `menu` as `Expected` values.
  static func items(of menu: NSMenu) -> [Expected] {
    menu.items.map { item in
      if item.isSeparatorItem { return .separator }
      if let submenu = item.submenu { return .submenu(submenu.title) }
      return .command(
        item.title, key: item.keyEquivalent,
        modifiers: item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask),
        action: item.action.map(NSStringFromSelector) ?? "none")
    }
  }

  /// The top-level menu titled `title`.
  static func menu(_ title: String, in built: MainMenu.Built) throws -> NSMenu {
    try #require(built.mainMenu.items.first { $0.submenu?.title == title }?.submenu)
  }

  /// The main menu holds the app menu, Edit and Window, in that order, each an item opening
  /// its submenu; the Services and Window menus AppKit is told about are those submenus.
  @Test("three menus: the app menu, Edit and Window")
  func topLevel() throws {
    let built = MainMenu.make()
    #expect(built.mainMenu.items.map(\.title) == ["muxFinder", "Edit", "Window"])
    #expect(built.mainMenu.items.map { $0.submenu?.title } == ["muxFinder", "Edit", "Window"])
    #expect(built.mainMenu.items.allSatisfy { $0.action == nil || $0.submenu != nil })
    #expect(try Self.menu("Window", in: built) === built.windowsMenu)
    let services = try Self.menu("muxFinder", in: built).items.first { $0.title == "Services" }
    #expect(services?.submenu === built.servicesMenu)
    #expect(built.servicesMenu.title == "Services")
  }

  /// The app menu: About, Services, Hide (⌘H), Hide others (⌥⌘H), Show all, Quit (⌘Q,
  /// `terminate:`, so the delegate's orderly shutdown runs); the app's name comes from the
  /// argument.
  @Test("the app menu: About, Services, Hide, Hide others, Show all, Quit")
  func appMenu() throws {
    let built = MainMenu.make()
    #expect(
      Self.items(of: try Self.menu("muxFinder", in: built)) == [
        .command(
          "About muxFinder", key: "", modifiers: [], action: "orderFrontStandardAboutPanel:"),
        .separator,
        .submenu("Services"),
        .separator,
        .command("Hide muxFinder", key: "h", modifiers: .command, action: "hide:"),
        .command(
          "Hide others", key: "h", modifiers: [.command, .option], action: "hideOtherApplications:"),
        .command("Show all", key: "", modifiers: [], action: "unhideAllApplications:"),
        .separator,
        .command("Quit muxFinder", key: "q", modifiers: .command, action: "terminate:"),
      ])
    let other = MainMenu.make(appName: "Other")
    #expect(other.mainMenu.items.first?.submenu?.title == "Other")
    #expect(other.mainMenu.items.first?.submenu?.items.last?.title == "Quit Other")
  } // End of func appMenu()

  /// Edit: Undo (⌘Z), Redo (⇧⌘Z), Cut (⌘X), Copy (⌘C), Paste (⌘V), Paste and match style
  /// (⌥⇧⌘V), Delete (no key) and Select all (⌘A), with the standard responder actions.
  @Test("Edit: the standard editing commands and their keys")
  func editMenu() throws {
    let built = MainMenu.make()
    #expect(
      Self.items(of: try Self.menu("Edit", in: built)) == [
        .command("Undo", key: "z", modifiers: .command, action: "undo:"),
        .command("Redo", key: "z", modifiers: [.command, .shift], action: "redo:"),
        .separator,
        .command("Cut", key: "x", modifiers: .command, action: "cut:"),
        .command("Copy", key: "c", modifiers: .command, action: "copy:"),
        .command("Paste", key: "v", modifiers: .command, action: "paste:"),
        .command(
          "Paste and match style", key: "v", modifiers: [.command, .option, .shift],
          action: "pasteAsPlainText:"),
        .command("Delete", key: "", modifiers: [], action: "delete:"),
        .command("Select all", key: "a", modifiers: .command, action: "selectAll:"),
      ])
  } // End of func editMenu()

  /// Window: Close (⌘W, `performClose:`), Minimize (⌘M), Zoom, Bring all to front.
  @Test("Window: Close, Minimize, Zoom, Bring all to front")
  func windowMenu() throws {
    let built = MainMenu.make()
    #expect(
      Self.items(of: try Self.menu("Window", in: built)) == [
        .command("Close", key: "w", modifiers: .command, action: "performClose:"),
        .command("Minimize", key: "m", modifiers: .command, action: "performMiniaturize:"),
        .command("Zoom", key: "", modifiers: [], action: "performZoom:"),
        .separator,
        .command("Bring all to front", key: "", modifiers: [], action: "arrangeInFront:"),
      ])
  } // End of func windowMenu()

  /// Every command goes to the first responder (no target), so it reaches the key window,
  /// a non-activating panel included; no two commands share a key equivalent; and there is no
  /// Settings item, so ⌘, stays the popover's and the switcher's (their key monitor) as before.
  @Test("commands go to the first responder, keys are unique, no ⌘, item")
  func targetsAndKeys() {
    let built = MainMenu.make()
    let commands = built.mainMenu.items.compactMap(\.submenu).flatMap(\.items)
      .filter { !$0.isSeparatorItem && $0.submenu == nil }
    #expect(commands.count == 17)
    #expect(commands.allSatisfy { $0.target == nil && $0.action != nil })
    let keys = commands.filter { !$0.keyEquivalent.isEmpty }
      .map { "\($0.keyEquivalentModifierMask.rawValue) \($0.keyEquivalent)" }
    #expect(Set(keys).count == keys.count)
    #expect(!commands.contains { $0.keyEquivalent == "," })
    #expect(!commands.contains { $0.title.localizedCaseInsensitiveContains("settings") })
  } // End of func targetsAndKeys()

  /// Close (⌘W) is enabled for the Settings and onboarding window's class and disabled for
  /// muxFinder's borderless panels (the popover's and the switcher's), so neither ⌘W nor
  /// AppKit's "Close All" alternate can act on a panel. The windows are never shown.
  @Test("Close is enabled for Settings and onboarding, not for the panels")
  func closeValidation() throws {
    _ = NSApplication.shared
    let built = MainMenu.make()
    let close = try #require(
      try Self.menu("Window", in: built).items.first { $0.title == "Close" })
    let panel = PopoverPanelWindow(contentView: NSView())
    let settings = SettingsWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
      defer: true)
    settings.isReleasedWhenClosed = false
    #expect(!panel.validateMenuItem(close))
    #expect(settings.validateMenuItem(close))
  } // End of func closeValidation()
}
