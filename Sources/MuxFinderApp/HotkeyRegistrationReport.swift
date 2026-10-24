import AppKit
import Darwin
import Foundation
import MuxFinderCore
import MuxFinderUI

/// `--report-hotkey-registration` (PLAN.md D32, Phase I-3): proves in this process that
/// Carbon's hotkey registration works as the session switcher shortcut relies on, then exits.
///
/// - **What it does:** registers fixed test combinations on F19 and J, which are unlikely to be
///   in use (never the user's saved shortcut; `preferences.json` is never read or written),
///   through the app's own `CarbonHotkeyRegistrar`, and prints one line per check: ⌃⌥⇧⌘F19
///   registers; a second registration of it is refused as taken; it unregisters; it registers
///   and unregisters again; ⌥F19, ⌥⇧F19, ⌥J and ⌥⇧J register, as `GlobalShortcut.check`
///   assumes when it only warns about them (`optionOnly`; were it to refuse them, refused would
///   be expected). Each registration is undone at once, and `unregisterAll()` runs before the
///   process exits.
/// - **What it never does:** no window, menu bar item, engine, host list or iTerm2; no event
///   is posted or synthesized and nothing is pressed, so it proves registration and its
///   refusals, never that a press fires (that is a check by hand).
/// - **Signals:** SIGTERM and SIGINT are blocked for the checks, so one arriving meanwhile stays
///   pending until every registration is undone; the run then exits 3.
/// - **Exit status:** 0 every check as expected, 1 a check failed (or an unregistration
///   failed), 3 interrupted by SIGTERM or SIGINT. Usage errors exit 2 before this runs.
@MainActor
enum HotkeyRegistrationReport {
  /// The prefix of every line.
  static let prefix = "muxFinder hotkey registration: "
  /// The F19 key with every modifier: the combination the checks register and refuse.
  static let fullCombination = GlobalShortcut(
    keyCode: GlobalShortcut.KeyCode.f19, modifiers: [.control, .option, .shift, .command])
  /// The ⌥-only and ⌥⇧-only combinations, on F19 and on J.
  static let optionOnlyCombinations = [
    GlobalShortcut(keyCode: GlobalShortcut.KeyCode.f19, modifiers: .option),
    GlobalShortcut(keyCode: GlobalShortcut.KeyCode.f19, modifiers: [.option, .shift]),
    GlobalShortcut(keyCode: GlobalShortcut.KeyCode.letterJ, modifiers: .option),
    GlobalShortcut(keyCode: GlobalShortcut.KeyCode.letterJ, modifiers: [.option, .shift]),
  ]
  /// The layout the lines name keys with, so they read the same on every Mac.
  static let layout = StaticKeyboardLayout(characters: [GlobalShortcut.KeyCode.letterJ: "j"])

  /// What one registration came to.
  enum Outcome: Equatable {
    /// Registered (and undone at once unless the next check needs it).
    case registered(HotkeyToken)
    /// Refused with this error.
    case refused(HotkeyRegistrationError)

    /// "registered", "taken", "refused (invalid(-9868))".
    var text: String {
      switch self {
      case .registered: return "registered"
      case .refused(.taken): return "taken (eventHotKeyExistsErr)"
      case .refused(let error): return "refused (\(error.code))"
      }
    }
  }

  /// Runs the checks, prints them and exits; never returns.
  static func run() -> Never {
    var blocked = sigset_t()
    sigemptyset(&blocked)
    sigaddset(&blocked, SIGTERM)
    sigaddset(&blocked, SIGINT)
    pthread_sigmask(SIG_BLOCK, &blocked, nil)
    _ = NSApplication.shared
    let registrar = CarbonHotkeyRegistrar()
    var lines = ["\(prefix)macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]
    var failures = 0

    /// Records one check: its line, and whether it went as expected.
    func check(_ title: String, _ result: String, expected: Bool, expectation: String) {
      lines.append("\(prefix)\(title): \(result) (expected \(expectation))")
      if !expected { failures += 1 }
    }

    let full = label(fullCombination)
    let first = register(fullCombination, with: registrar)
    check("register \(full)", first.text, expected: isRegistered(first), expectation: "registered")
    let second = register(fullCombination, with: registrar)
    check(
      "register \(full) again", second.text, expected: second == .refused(.taken),
      expectation: "taken")
    if case .registered(let token) = second { try? registrar.unregister(token) }
    if case .registered(let token) = first {
      let result = unregister(token, with: registrar)
      check(
        "unregister \(full)", result ?? "unregistered", expected: result == nil,
        expectation: "unregistered")
    }
    let again = register(fullCombination, with: registrar)
    var againText = again.text
    var againExpected = isRegistered(again)
    if case .registered(let token) = again, let failure = unregister(token, with: registrar) {
      againText += ", then unregistering failed: \(failure)"
      againExpected = false
    } else if isRegistered(again) {
      againText += " and unregistered"
    }
    check(
      "register \(full) after unregistering", againText, expected: againExpected,
      expectation: "registered and unregistered")
    for combination in optionOnlyCombinations {
      let outcome = register(combination, with: registrar)
      if case .registered(let token) = outcome { try? registrar.unregister(token) }
      let refusedByMuxFinder = !combination.check.isUsable
      check(
        "register \(label(combination)) (only ⌥ or ⌥⇧)", outcome.text,
        expected: isRegistered(outcome) != refusedByMuxFinder,
        expectation: refusedByMuxFinder
          ? "refused, as muxFinder refuses it" : "registered, as muxFinder only warns about it")
    } // End of loop over the ⌥-only combinations
    let leftover = registrar.unregisterAll()
    if leftover > 0 { failures += 1 }
    var pending = sigset_t()
    sigpending(&pending)
    let interrupted = sigismember(&pending, SIGTERM) == 1 || sigismember(&pending, SIGINT) == 1
    let checks = lines.count - 1
    if interrupted {
      lines.append("\(prefix)interrupted by a signal; nothing left registered")
    } else if failures == 0 {
      lines.append("\(prefix)\(checks) checks, all as expected; nothing left registered")
    } else {
      lines.append(
        "\(prefix)\(failures) of \(checks) checks not as expected; "
          + (leftover == 0 ? "nothing left registered" : "\(leftover) not unregistered"))
    }
    FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    exit(interrupted ? 3 : failures == 0 ? 0 : 1)
  } // End of static func run()

  /// Registers `shortcut` and says how it went.
  static func register(_ shortcut: GlobalShortcut, with registrar: CarbonHotkeyRegistrar)
    -> Outcome
  {
    do throws(HotkeyRegistrationError) {
      return .registered(try registrar.register(shortcut))
    } catch {
      return .refused(error)
    }
  }

  /// Unregisters `token`; returns the failure's code, or `nil` when it worked.
  static func unregister(_ token: HotkeyToken, with registrar: CarbonHotkeyRegistrar) -> String? {
    do throws(HotkeyRegistrationError) {
      try registrar.unregister(token)
      return nil
    } catch {
      return "failed (\(error.code))"
    }
  }

  /// Whether `outcome` is a registration.
  static func isRegistered(_ outcome: Outcome) -> Bool {
    if case .registered = outcome { return true }
    return false
  }

  /// `shortcut`'s label on the fixed layout.
  static func label(_ shortcut: GlobalShortcut) -> String {
    GlobalShortcutLabel(shortcut, layout: layout).text
  }
}
