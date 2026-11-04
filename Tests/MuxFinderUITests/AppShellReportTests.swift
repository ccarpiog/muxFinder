import AppKit
import Testing

@testable import MuxFinderUI

/// The app shell check's listing (`--report-menu-bar-item`, PLAN.md D22, D33): the status item
/// lines as before, every other window by title, class, visibility and level, the launch's
/// Apple event, the main menu, the bounds and the cleaning of titles. Pure values, except one
/// test describing the real `MainMenu`.
@Suite("App shell report")
@MainActor
struct AppShellReportTests {
  /// A status-bar-level window at `x`.
  static func statusItem(x: CGFloat) -> AppShellReport.Window {
    AppShellReport.Window(
      title: "", className: "NSStatusBarWindow", isVisible: true,
      level: NSWindow.Level.statusBar.rawValue,
      frame: CGRect(x: x, y: 1698, width: 34, height: 30))
  }

  /// A normal-level window titled `title`.
  static func window(_ title: String, visible: Bool = true) -> AppShellReport.Window {
    AppShellReport.Window(
      title: title, className: "MuxFinderUI.SettingsWindow", isVisible: visible, level: 0,
      frame: .zero)
  }

  /// The status item lines are the ones the check always printed; every other window follows
  /// with its title, class, visibility and level, after a count of them and of the visible
  /// ones; then the launch line.
  @Test("status item lines as before, then the other windows and the launch")
  func windowsAndLaunch() {
    let lines = AppShellReport.lines(
      windows: [
        Self.statusItem(x: 1518),
        AppShellReport.Window(
          title: "", className: "MuxFinderUI.PopoverPanelWindow", isVisible: false, level: 101,
          frame: .zero),
        Self.statusItem(x: 0),
        Self.window("Welcome to muxFinder"),
      ],
      launch: .init(appleEvent: "oapp", isDefaultLaunch: true), mainMenu: [])
    #expect(
      lines == [
        "muxFinder menu bar item windows: 2",
        "muxFinder menu bar item: level 25 visible true frame {{1518, 1698}, {34, 30}}",
        "muxFinder menu bar item: level 25 visible true frame {{0, 1698}, {34, 30}}",
        "muxFinder other windows: 2, 1 visible",
        "muxFinder other window: \"\" class MuxFinderUI.PopoverPanelWindow visible false level 101",
        "muxFinder other window: \"Welcome to muxFinder\" class MuxFinderUI.SettingsWindow "
          + "visible true level 0",
        "muxFinder launch: Apple event oapp, default launch true",
        "muxFinder main menu: 0 menus, 0 items",
      ])
  } // End of func windowsAndLaunch()

  /// No launch description prints no launch line; an unknown one prints "none" and "unknown";
  /// no main menu prints "none".
  @Test("missing launch details and no main menu")
  func missingParts() {
    let none = AppShellReport.lines(windows: [], launch: nil, mainMenu: nil)
    #expect(
      none == [
        "muxFinder menu bar item windows: 0", "muxFinder other windows: 0, 0 visible",
        "muxFinder main menu: none",
      ])
    let unknown = AppShellReport.lines(
      windows: [], launch: .init(appleEvent: nil, isDefaultLaunch: nil), mainMenu: nil)
    #expect(unknown.contains("muxFinder launch: Apple event none, default launch unknown"))
  } // End of func missingParts()

  /// At most `maximumWindows` other windows and `maximumMenuItems` menu items are listed, each
  /// followed by the count of those left out.
  @Test("windows and menu items are bounded")
  func bounds() {
    let windows = (0..<40).map { Self.window("w\($0)") }
    let items = (0..<100).map { AppShellReport.MenuItem(menu: "M", title: "i\($0)") }
    let lines = AppShellReport.lines(
      windows: windows, launch: nil, mainMenu: [AppShellReport.Menu(title: "M", items: items)])
    #expect(lines.filter { $0.hasPrefix("muxFinder other window: ") }.count == 32)
    #expect(lines.contains("muxFinder other windows: 40, 40 visible"))
    #expect(lines.contains("muxFinder other windows not listed: 8"))
    #expect(lines.filter { $0.hasPrefix("muxFinder main menu item: ") }.count == 80)
    #expect(lines.contains("muxFinder main menu: 1 menus, 100 items"))
    #expect(lines.contains("muxFinder main menu items not listed: 20"))
  } // End of func bounds()

  /// A title is cut to `maximumTitleLength` characters with "…", its control characters are
  /// replaced and its quotes and backslashes escaped, so one line stays one line.
  @Test("titles are cut, cleaned and escaped")
  func titles() {
    #expect(AppShellReport.quoted("a\nb\t\"c\"\\") == "\"a?b?\\\"c\\\"\\\\\"")
    let long = String(repeating: "x", count: 100)
    #expect(AppShellReport.quoted(long) == "\"" + String(repeating: "x", count: 80) + "…\"")
  }

  /// Key equivalents read as modifier symbols, "+" and the key; keys that are not printable
  /// characters as `U+XXXX`; four-character codes as text when printable.
  @Test("key labels and four-character codes")
  func labels() {
    let redo = AppShellReport.MenuItem(
      menu: "Edit", title: "Redo", keyEquivalent: "z", modifiers: [.command, .shift])
    #expect(AppShellReport.keyLabel(redo) == "⇧⌘+z")
    let space = AppShellReport.MenuItem(
      menu: "Edit", title: "E", keyEquivalent: " ", modifiers: [.control, .command])
    #expect(AppShellReport.keyLabel(space) == "⌃⌘+U+0020")
    #expect(AppShellReport.keyLabel(.init(menu: "M", title: "T")) == "none")
    #expect(AppShellReport.fourCharacterCode(0x6F61_7070) == "oapp")
    #expect(AppShellReport.fourCharacterCode(1) == "1")
  } // End of func labels()

  /// The real main menu reads as its items with their keys, actions and first-responder
  /// targets, separators and submenus included (AppKit gives a submenu's item
  /// `submenuAction:` with the submenu as its target).
  @Test("the real main menu's description")
  func mainMenuDescription() throws {
    let menus = try #require(AppShellReport.describe(mainMenu: MainMenu.make().mainMenu))
    let lines = AppShellReport.menuLines(menus)
    #expect(lines.first == "muxFinder main menu: 3 menus, 23 items")
    #expect(lines.contains("muxFinder main menu: \"Edit\", 9 items"))
    #expect(
      lines.contains(
        "muxFinder main menu item: \"muxFinder\" › \"Quit muxFinder\" key ⌘+q action terminate: "
          + "target first responder"))
    #expect(
      lines.contains(
        "muxFinder main menu item: \"Edit\" › \"Paste and match style\" key ⌥⇧⌘+v action "
          + "pasteAsPlainText: target first responder"))
    #expect(
      lines.contains(
        "muxFinder main menu item: \"muxFinder\" › \"Services\" key none action submenuAction: "
          + "target NSMenu submenu 0 items"))
    #expect(lines.contains("muxFinder main menu item: \"Window\" › separator"))
  } // End of func mainMenuDescription()
}
