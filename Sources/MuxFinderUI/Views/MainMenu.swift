import AppKit

/// muxFinder's main menu (PLAN.md D33), built by hand for the menu bar app's plain
/// `NSApplication`.
///
/// An accessory app shows no menu bar, so nobody sees this menu: it is there for its key
/// equivalents, which AppKit tries after the key window's own (`performKeyEquivalent(with:)`).
/// They are the ones SwiftUI's standard main menu gave muxFinder before D33 (the Edit commands
/// the text fields use: the popover's search field, New session's name and directory, the
/// session switcher's field, Settings and onboarding; ⌘Q; ⌘H and ⌥⌘H; ⌘M), plus "Paste and
/// match style" (⌥⇧⌘V) and "Close" (⌘W). Every item goes to the first responder (no target),
/// so it reaches the key window whether or not the app is active, as a non-activating panel
/// is. "Quit" sends `terminate(_:)`, so the app delegate's orderly shutdown runs.
///
/// There is no Settings item: SwiftUI's menu had none either (its Settings item was removed),
/// and ⌘, opens muxFinder's Settings window only from the popover and the session switcher,
/// whose key monitor takes it before any menu (D22, D32). AppKit adds its own items to the
/// Edit menu (AutoFill, Start Dictation, Emoji & Symbols) and fills the Services menu and the
/// Window menu's window list. Titles are sentence case (D10).
@MainActor
public enum MainMenu {
  /// The application's name in the app menu's titles.
  public static let defaultAppName = "muxFinder"

  /// A built main menu, with the submenus AppKit is told about.
  public struct Built {
    /// The main menu: the app menu, Edit and Window.
    public let mainMenu: NSMenu
    /// The app menu's Services submenu (`NSApplication.servicesMenu`).
    public let servicesMenu: NSMenu
    /// The Window menu (`NSApplication.windowsMenu`).
    public let windowsMenu: NSMenu
  }

  /// Builds the main menu for an app named `appName`.
  public static func make(appName: String = defaultAppName) -> Built {
    let services = NSMenu(title: "Services")
    let appMenu = menu(
      appName,
      [
        item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
        .separator(),
        submenuItem("Services", services),
        .separator(),
        item("Hide \(appName)", #selector(NSApplication.hide(_:)), key: "h"),
        item(
          "Hide others", #selector(NSApplication.hideOtherApplications(_:)), key: "h",
          modifiers: [.command, .option]),
        item("Show all", #selector(NSApplication.unhideAllApplications(_:))),
        .separator(),
        item("Quit \(appName)", #selector(NSApplication.terminate(_:)), key: "q"),
      ])
    let edit = menu(
      "Edit",
      [
        item("Undo", Selector(("undo:")), key: "z"),
        item("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift]),
        .separator(),
        item("Cut", #selector(NSText.cut(_:)), key: "x"),
        item("Copy", #selector(NSText.copy(_:)), key: "c"),
        item("Paste", #selector(NSText.paste(_:)), key: "v"),
        item(
          "Paste and match style", #selector(NSTextView.pasteAsPlainText(_:)), key: "v",
          modifiers: [.command, .option, .shift]),
        item("Delete", #selector(NSText.delete(_:))),
        item("Select all", #selector(NSText.selectAll(_:)), key: "a"),
      ])
    let window = menu(
      "Window",
      [
        item("Close", #selector(NSWindow.performClose(_:)), key: "w"),
        item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"),
        item("Zoom", #selector(NSWindow.performZoom(_:))),
        .separator(),
        item("Bring all to front", #selector(NSApplication.arrangeInFront(_:))),
      ])
    let main = NSMenu(title: "Main menu")
    for submenu in [appMenu, edit, window] {
      main.addItem(submenuItem(submenu.title, submenu))
    }
    return Built(mainMenu: main, servicesMenu: services, windowsMenu: window)
  } // End of static func make(appName:)

  /// Builds the main menu and makes it `application`'s, with its Services and Window menus.
  public static func install(in application: NSApplication, appName: String = defaultAppName) {
    let built = make(appName: appName)
    application.mainMenu = built.mainMenu
    application.servicesMenu = built.servicesMenu
    application.windowsMenu = built.windowsMenu
  }

  /// A menu titled `title` holding `items`.
  private static func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
    let menu = NSMenu(title: title)
    for item in items { menu.addItem(item) }
    return menu
  }

  /// A command sent to the first responder, with an optional key equivalent (⌘ alone unless
  /// `modifiers` says otherwise).
  private static func item(
    _ title: String, _ action: Selector, key: String = "",
    modifiers: NSEvent.ModifierFlags = .command
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
    item.target = nil
    return item
  }

  /// An item opening `submenu`.
  private static func submenuItem(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.submenu = submenu
    return item
  }
}
