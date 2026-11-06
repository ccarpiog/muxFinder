import AppKit
import CoreServices
import Foundation
import MuxFinderCore

/// `muxfinder-probe terminals list`: read-only facts about the terminal apps muxFinder knows
/// (PLAN.md D38, Phase I-12a): iTerm2, Terminal and Ghostty, each found through LaunchServices
/// by bundle identifier, with its path, version, whether it is running, and the Automation
/// permission's state read with `AEDeterminePermissionToAutomateTarget` and `askUserIfNeeded`
/// false (`AutomationPermission`).
///
/// It launches nothing, sends no Apple event (the permission check sends none and never
/// prompts), writes nothing and contacts no iTerm2 API. The permission is the one of the process
/// macOS holds responsible for this command: the terminal app it runs in. Phase I-12b adds
/// the terminal definitions.
enum TerminalsCommand {
  /// Usage lines for this subcommand group.
  static let usage = """
      terminals list
          Print iTerm2, Terminal and Ghostty as JSON: found through LaunchServices by bundle
          identifier, path, version, whether running, and the Automation permission's state
          (granted, denied, notDetermined, targetNotRunning, or other with the status), read
          without a prompt for the app this command runs in. Read-only: launches nothing,
          sends no Apple event, writes nothing.
    """

  /// One terminal app muxFinder knows.
  struct Known: Sendable {
    /// A short stable id.
    let id: String
    /// The app's name.
    let name: String
    /// Its bundle identifier.
    let bundleIdentifier: String
  }

  /// The apps listed, in this order.
  static let known = [
    Known(id: "iterm2", name: "iTerm2", bundleIdentifier: "com.googlecode.iterm2"),
    Known(id: "terminal", name: "Terminal", bundleIdentifier: "com.apple.Terminal"),
    Known(id: "ghostty", name: "Ghostty", bundleIdentifier: "com.mitchellh.ghostty"),
  ]

  /// Runs the subcommand named by the first argument and returns the exit status.
  static func run(_ arguments: [String]) async -> Int32 {
    switch arguments {
    case ["list"]:
      let output = await MainActor.run { ListOutput(terminals: known.map(Entry.init)) }
      return HostsCommand.printJSON(output)
    case ["--help"], ["-h"], ["help"]:
      print("usage:\n\(usage)")
      return 0
    default:
      printError("muxfinder-probe: terminals takes list\n\nusage:\n\(usage)")
      return EX_USAGE
    }
  } // End of func run(_:)

  /// The JSON printed by `list`.
  struct ListOutput: Encodable {
    /// Whose permission is read.
    let permissionOf =
      "the app macOS holds responsible for this command (the terminal it runs in); "
      + "read with askUserIfNeeded false, so no prompt"
    /// One entry per known app.
    let terminals: [Entry]
  }

  /// One app in the JSON.
  struct Entry: Encodable {
    /// The short id.
    let id: String
    /// The app's name.
    let name: String
    /// The bundle identifier.
    let bundleIdentifier: String
    /// Whether LaunchServices knows an app with it.
    let installed: Bool
    /// The app's path, when installed.
    let path: String?
    /// `CFBundleShortVersionString`, when installed and readable.
    let version: String?
    /// Whether an instance runs now.
    let running: Bool
    /// The permission's state (`AutomationPermission.kind`).
    let automation: String
    /// The raw status `AEDeterminePermissionToAutomateTarget` returned.
    let automationStatus: Int32

    /// Reads the facts about `app`.
    @MainActor
    init(_ app: Known) {
      id = app.id
      name = app.name
      bundleIdentifier = app.bundleIdentifier
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier)
      installed = url != nil
      path = url.map { url -> String in
        let text = url.path(percentEncoded: false)
        return text.count > 1 && text.hasSuffix("/") ? String(text.dropLast()) : text
      }
      version = url.flatMap {
        Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String
      }
      running = !NSRunningApplication.runningApplications(
        withBundleIdentifier: app.bundleIdentifier
      ).isEmpty
      automationStatus = TerminalsCommand.permissionStatus(for: app.bundleIdentifier)
      automation = AutomationPermission(status: automationStatus).kind
    } // End of init(_:)
  } // End of struct Entry

  /// The status of `AEDeterminePermissionToAutomateTarget` for the app `bundleIdentifier`, any
  /// event class and id, `askUserIfNeeded` false: it sends no event, never prompts and never
  /// launches the app (-600 when it is not running). -1 when the address cannot be made.
  static func permissionStatus(for bundleIdentifier: String) -> Int32 {
    var address = AEAddressDesc()
    let bytes = Array(bundleIdentifier.utf8)
    let created = bytes.withUnsafeBytes { buffer in
      AECreateDesc(
        DescType(typeApplicationBundleID), buffer.baseAddress, buffer.count, &address)
    }
    guard created == noErr else { return -1 }
    defer { AEDisposeDesc(&address) }
    return AEDeterminePermissionToAutomateTarget(
      &address, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
  } // End of static func permissionStatus(for:)
} // End of enum TerminalsCommand
