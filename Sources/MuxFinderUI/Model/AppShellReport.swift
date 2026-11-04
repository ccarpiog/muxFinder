import AppKit

/// The app shell check's listing (`--report-menu-bar-item`, PLAN.md D22, D33), read-only: the
/// app's own status-bar-level windows (the menu bar item and AppKit's replicas of it, with
/// their frames), every other window the app has (`NSApp.windows`: its title, class,
/// visibility and level, never its contents), how the launch reached the app, and its main
/// menu (each menu's items with their key equivalents and actions, one level deep), so an
/// unexpected window or a missing menu item shows in the output.
///
/// Every line starts with `muxFinder `. The listing is bounded: at most `maximumWindows` other
/// windows and `maximumMenuItems` menu items are listed (a count of the rest follows), and a
/// title is cut to `maximumTitleLength` characters with its control characters replaced.
public enum AppShellReport {
  /// The most other windows listed one by one.
  public static let maximumWindows = 32
  /// The most main menu items listed one by one.
  public static let maximumMenuItems = 80
  /// The most characters of a title printed.
  public static let maximumTitleLength = 80

  /// One window as the check describes it.
  public struct Window: Sendable, Hashable {
    /// Its title.
    public var title: String
    /// Its class name.
    public var className: String
    /// Whether it is visible (`NSWindow.isVisible`).
    public var isVisible: Bool
    /// Its window level's raw value.
    public var level: Int
    /// Its frame in screen coordinates.
    public var frame: CGRect

    /// A window description.
    public init(title: String, className: String, isVisible: Bool, level: Int, frame: CGRect) {
      self.title = title
      self.className = className
      self.isVisible = isVisible
      self.level = level
      self.frame = frame
    }

    /// The description of `window`.
    @MainActor
    public init(_ window: NSWindow) {
      self.init(
        title: window.title, className: NSStringFromClass(type(of: window)),
        isVisible: window.isVisible, level: window.level.rawValue, frame: window.frame)
    }
  }

  /// One main menu item as the check describes it.
  public struct MenuItem: Sendable, Equatable {
    /// The title of the top-level menu it is in.
    public var menu: String
    /// Its title (empty for a separator).
    public var title: String
    /// Whether it is a separator.
    public var isSeparator: Bool
    /// Its key equivalent (empty for none).
    public var keyEquivalent: String
    /// Its key equivalent's modifiers (device-independent flags only).
    public var modifiers: NSEvent.ModifierFlags
    /// Its action's selector name, if it has one.
    public var action: String?
    /// Its target's class name; `nil` when it goes to the first responder.
    public var target: String?
    /// The number of items in its submenu, when it has one.
    public var submenuItemCount: Int?
    /// Whether it is hidden.
    public var isHidden: Bool

    /// A menu item description.
    public init(
      menu: String, title: String, isSeparator: Bool = false, keyEquivalent: String = "",
      modifiers: NSEvent.ModifierFlags = [], action: String? = nil, target: String? = nil,
      submenuItemCount: Int? = nil, isHidden: Bool = false
    ) {
      self.menu = menu
      self.title = title
      self.isSeparator = isSeparator
      self.keyEquivalent = keyEquivalent
      self.modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
      self.action = action
      self.target = target
      self.submenuItemCount = submenuItemCount
      self.isHidden = isHidden
    } // End of the memberwise init(menu:title:…)

    /// The description of `item`, in the top-level menu titled `menu`.
    @MainActor
    public init(_ item: NSMenuItem, in menu: String) {
      self.init(
        menu: menu, title: item.title, isSeparator: item.isSeparatorItem,
        keyEquivalent: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask,
        action: item.action.map(NSStringFromSelector),
        target: item.target.map { NSStringFromClass(type(of: $0)) },
        submenuItemCount: item.submenu?.items.count, isHidden: item.isHidden)
    }
  }

  /// One top-level menu of the main menu.
  public struct Menu: Sendable, Equatable {
    /// Its title.
    public var title: String
    /// Its items, in order.
    public var items: [MenuItem]

    /// A menu description.
    public init(title: String, items: [MenuItem]) {
      self.title = title
      self.items = items
    }
  }

  /// How the launch reached the app: the Apple event being handled when launching finished
  /// (LaunchServices sends `oapp` to an app it opens), and AppKit's "default launch" flag.
  public struct Launch: Sendable, Hashable {
    /// The four-character code of the Apple event current at `applicationDidFinishLaunching`,
    /// `nil` when there was none.
    public var appleEvent: String?
    /// The launch notification's `NSApplicationLaunchIsDefaultLaunchKey`, `nil` when absent.
    public var isDefaultLaunch: Bool?

    /// A launch description.
    public init(appleEvent: String?, isDefaultLaunch: Bool?) {
      self.appleEvent = appleEvent
      self.isDefaultLaunch = isDefaultLaunch
    }

    /// The launch as `applicationDidFinishLaunching(_:)`'s `notification` and the Apple event
    /// manager show it at that moment.
    @MainActor
    public init(finishedLaunching notification: Notification) {
      let event = NSAppleEventManager.shared().currentAppleEvent
      self.init(
        appleEvent: event.map { AppShellReport.fourCharacterCode($0.eventID) },
        isDefaultLaunch: notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey]
          as? Bool)
    }
  }

  /// The lines for `windows` (all of the app's), `launch` and the main menu (`nil`: the app
  /// has none).
  public static func lines(windows: [Window], launch: Launch?, mainMenu: [Menu]?) -> [String] {
    let statusBar = windows.filter { $0.level == NSWindow.Level.statusBar.rawValue }
    var lines = ["muxFinder menu bar item windows: \(statusBar.count)"]
    for window in statusBar {
      lines.append(
        "muxFinder menu bar item: level \(window.level) visible \(window.isVisible) "
          + "frame \(NSStringFromRect(window.frame))")
    }
    let others = windows.filter { $0.level != NSWindow.Level.statusBar.rawValue }
    let visible = others.filter(\.isVisible).count
    lines.append("muxFinder other windows: \(others.count), \(visible) visible")
    for window in others.prefix(maximumWindows) {
      lines.append(
        "muxFinder other window: \(quoted(window.title)) class \(window.className) "
          + "visible \(window.isVisible) level \(window.level)")
    }
    if others.count > maximumWindows {
      lines.append("muxFinder other windows not listed: \(others.count - maximumWindows)")
    }
    if let launch {
      let event = launch.appleEvent ?? "none"
      let isDefault = launch.isDefaultLaunch.map(String.init) ?? "unknown"
      lines.append("muxFinder launch: Apple event \(event), default launch \(isDefault)")
    }
    lines += menuLines(mainMenu)
    return lines
  } // End of static func lines(windows:launch:mainMenu:)

  /// The main menu's lines: a summary, each top-level menu's title and its items, at most
  /// `maximumMenuItems` items in all.
  static func menuLines(_ mainMenu: [Menu]?) -> [String] {
    guard let mainMenu else { return ["muxFinder main menu: none"] }
    let itemCount = mainMenu.reduce(0) { $0 + $1.items.count }
    var lines = ["muxFinder main menu: \(mainMenu.count) menus, \(itemCount) items"]
    var listed = 0
    for menu in mainMenu {
      lines.append("muxFinder main menu: \(quoted(menu.title)), \(menu.items.count) items")
      for item in menu.items {
        guard listed < maximumMenuItems else { break }
        listed += 1
        lines.append("muxFinder main menu item: \(describe(item))")
      }
    }
    if itemCount > listed {
      lines.append("muxFinder main menu items not listed: \(itemCount - listed)")
    }
    return lines
  } // End of static func menuLines(_:)

  /// One item's description: its menu and title (or "separator"), key equivalent, action,
  /// target and submenu.
  static func describe(_ item: MenuItem) -> String {
    let place = quoted(item.menu) + " › "
    guard !item.isSeparator else { return place + "separator" }
    var text = place + quoted(item.title) + " key " + keyLabel(item)
    text += " action " + (item.action ?? "none")
    text += " target " + (item.target ?? "first responder")
    if let count = item.submenuItemCount { text += " submenu \(count) items" }
    if item.isHidden { text += " hidden" }
    return text
  }

  /// A key equivalent as modifier symbols, a plus sign and the key (`⇧⌘+z`, `⌘+,`); a key
  /// that is not a printable character is written `U+XXXX`; "none" without a key equivalent.
  static func keyLabel(_ item: MenuItem) -> String {
    guard !item.keyEquivalent.isEmpty else { return "none" }
    let flags: [(NSEvent.ModifierFlags, String)] = [
      (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"), (.function, "fn"),
    ]
    let symbols = flags.filter { item.modifiers.contains($0.0) }.map(\.1).joined()
    let key = item.keyEquivalent.unicodeScalars.map { scalar in
      let category = scalar.properties.generalCategory
      let printable =
        scalar.value > 0x20 && category != .control && category != .privateUse
        && category != .format && !scalar.properties.isWhitespace
      return printable ? String(scalar) : String(format: "U+%04X", scalar.value)
    }.joined()
    return symbols + "+" + key
  } // End of static func keyLabel(_:)

  /// `text` in double quotes, cut to `maximumTitleLength` characters (with "…"), its control
  /// characters replaced by "?" and its double quotes and backslashes escaped.
  static func quoted(_ text: String) -> String {
    var cut = String(text.prefix(maximumTitleLength))
    if text.count > maximumTitleLength { cut += "…" }
    let cleaned = cut.unicodeScalars.map { scalar -> String in
      if scalar.properties.generalCategory == .control { return "?" }
      if scalar == "\"" || scalar == "\\" { return "\\" + String(scalar) }
      return String(scalar)
    }.joined()
    return "\"" + cleaned + "\""
  }

  /// A four-character code as text (`oapp`), or its number when it is not printable ASCII.
  static func fourCharacterCode(_ code: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
    guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return String(code) }
    return String(decoding: bytes, as: UTF8.self)
  }

  /// The main menu's description, `nil` when the app has none.
  @MainActor
  public static func describe(mainMenu: NSMenu?) -> [Menu]? {
    guard let mainMenu else { return nil }
    return mainMenu.items.map { top in
      let title = top.submenu?.title ?? top.title
      return Menu(
        title: title, items: (top.submenu?.items ?? []).map { MenuItem($0, in: title) })
    }
  }

  /// The lines for this app now: `NSApp.windows`, `launch` and `NSApp.mainMenu`.
  @MainActor
  public static func currentLines(launch: Launch?) -> [String] {
    lines(
      windows: NSApp.windows.map(Window.init), launch: launch,
      mainMenu: describe(mainMenu: NSApp.mainMenu))
  }
}
