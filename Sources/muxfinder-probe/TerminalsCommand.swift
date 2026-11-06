import AppKit
import CoreServices
import Foundation
import MuxFinderCore

/// `muxfinder-probe terminals list`: read-only facts about the terminal apps muxFinder knows
/// (PLAN.md D38, Phases I-12a and I-12b1): iTerm2, Terminal and Ghostty, each found through
/// LaunchServices by bundle identifier, with its path, version, whether it is running, and the
/// Automation permission's state read with `AEDeterminePermissionToAutomateTarget` and
/// `askUserIfNeeded` false (`AutomationPermission`); then the terminal definitions
/// (`TerminalDefinitionLoader`) with the same facts for each definition's app, and every file
/// that could not be used with its problem.
///
/// It launches nothing, sends no Apple event (the permission check sends none and never
/// prompts), compiles no script, writes nothing and contacts no iTerm2 API. The permission is
/// the one of the process macOS holds responsible for this command: the terminal app it runs
/// in.
enum TerminalsCommand {
  /// Usage lines for this subcommand group.
  static let usage = """
      terminals list [--builtin-directory <dir>] [--user-directory <dir>]
          Print iTerm2, Terminal and Ghostty as JSON: found through LaunchServices by bundle
          identifier, path, version, whether running, and the Automation permission's state
          (granted, denied, notDetermined, targetNotRunning, or other with the status), read
          without a prompt for the app this command runs in. Then the terminal definitions
          (id, name, source builtIn, user or userOverride, open kind and command form, focus
          kind, and the same facts for each one's app, with whether it meets the minimum
          version) and the files that could not be used, with their problems. Built-ins come
          from --builtin-directory, by default the repository's Resources/Terminals when run
          from the repository, else none; user definitions from --user-directory, by default
          ~/Library/Application Support/muxFinder/terminals. Read-only: launches nothing,
          sends no Apple event, compiles no script, writes nothing.
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

  /// The folders `list` reads definitions from.
  struct Folders {
    /// The built-in folder, if any.
    var builtIn: URL?
    /// The user's folder.
    var user: URL
  }

  /// Runs the subcommand named by the first argument and returns the exit status.
  static func run(_ arguments: [String]) async -> Int32 {
    switch arguments.first {
    case "list":
      guard let folders = parseListOptions(Array(arguments.dropFirst())) else {
        printError(
          "muxfinder-probe: terminals list takes --builtin-directory <dir> and "
            + "--user-directory <dir>, each at most once\n\nusage:\n\(usage)")
        return EX_USAGE
      }
      let loader = TerminalDefinitionLoader(
        builtInDirectory: folders.builtIn, userDirectory: folders.user)
      let catalog = loader.load()
      let output = await MainActor.run {
        ListOutput(
          terminals: known.map(Entry.init),
          builtInDirectory: folders.builtIn.map(PathText.of),
          userDirectory: PathText.of(folders.user),
          definitions: catalog.definitions.map(DefinitionEntry.init),
          problems: catalog.problems.map(ProblemEntry.init)
        )
      }
      return HostsCommand.printJSON(output)
    case "--help", "-h", "help":
      guard arguments.count == 1 else { break }
      print("usage:\n\(usage)")
      return 0
    default:
      break
    }
    printError("muxfinder-probe: terminals takes list\n\nusage:\n\(usage)")
    return EX_USAGE
  } // End of func run(_:)

  /// Reads `list`'s options; `nil` for anything else, or an option given twice or without a
  /// value. Paths are made absolute against the working directory and otherwise taken as
  /// given: never standardized (which would turn `/private/tmp` into the link `/tmp`) or
  /// resolved, so the loader's rules see the path the user typed.
  static func parseListOptions(_ arguments: [String]) -> Folders? {
    var builtIn: URL?
    var user: URL?
    var index = 0
    while index < arguments.count {
      guard index + 1 < arguments.count else { return nil }
      let value = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
      switch arguments[index] {
      case "--builtin-directory" where builtIn == nil: builtIn = value
      case "--user-directory" where user == nil: user = value
      default: return nil
      }
      index += 2
    } // End of loop over the options
    return Folders(
      builtIn: builtIn ?? repositoryBuiltInDirectory(),
      user: user ?? AppPaths.standard.terminalDefinitionsDirectory)
  } // End of static func parseListOptions(_:)

  /// The repository's `Resources/Terminals` when the working directory is the repository (it
  /// holds `Package.swift` and that folder), else `nil`.
  static func repositoryBuiltInDirectory() -> URL? {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let folder = root.appending(path: "Resources/Terminals", directoryHint: .isDirectory)
    var isDirectory: ObjCBool = false
    let manifest = root.appending(path: "Package.swift").path(percentEncoded: false)
    guard FileManager.default.fileExists(atPath: manifest),
      FileManager.default.fileExists(
        atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return nil }
    return folder
  }

  /// The JSON printed by `list`.
  struct ListOutput: Encodable {
    /// Whose permission is read.
    let permissionOf =
      "the app macOS holds responsible for this command (the terminal it runs in); "
      + "read with askUserIfNeeded false, so no prompt"
    /// One entry per known app.
    let terminals: [Entry]
    /// The built-in folder read, if any.
    let builtInDirectory: String?
    /// The user folder read.
    let userDirectory: String
    /// The usable definitions, by id.
    let definitions: [DefinitionEntry]
    /// The files and folders that could not be used.
    let problems: [ProblemEntry]
  } // End of struct ListOutput

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
      path = url.map(WorkspaceTerminalAppInspector.displayPath)
      version = url.flatMap {
        Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String
      }
      running = !NSRunningApplication.runningApplications(
        withBundleIdentifier: app.bundleIdentifier
      ).isEmpty
      automationStatus = AutomationPermission.status(forBundleIdentifier: app.bundleIdentifier)
      automation = AutomationPermission(status: automationStatus).kind
    } // End of init(_:)
  } // End of struct Entry

  /// One usable definition in the JSON, with its app's facts.
  struct DefinitionEntry: Encodable {
    /// The definition's id.
    let id: String
    /// Its display name.
    let displayName: String
    /// `builtIn`, `user` or `userOverride`.
    let source: String
    /// The definition file's name.
    let file: String
    /// The bundle identifier.
    let bundleIdentifier: String
    /// The minimum version.
    let minimumVersion: String
    /// `appleScript` or `exec`.
    let openKind: String
    /// `shellText` or `words` for `appleScript`; absent for `exec`.
    let commandForm: String?
    /// The script file's name for `appleScript`; absent for `exec`.
    let script: String?
    /// `tty`, `windowID` or `app`.
    let focusKind: String
    /// Whether the helper keeps its minimum lifetime.
    let keepsMinimumLifetime: Bool
    /// The app's facts.
    let app: AppEntry

    /// The entry for `loaded`, reading its app's facts.
    @MainActor
    init(_ loaded: LoadedTerminalDefinition) {
      let definition = loaded.definition
      id = definition.id
      displayName = definition.displayName
      source = loaded.source.rawValue
      file = loaded.fileName
      bundleIdentifier = definition.bundleIdentifier
      minimumVersion = definition.minimumVersion.text
      openKind = definition.open.kind
      commandForm = definition.open.commandForm?.rawValue
      script = loaded.script?.name
      focusKind = definition.focus.rawValue
      keepsMinimumLifetime = definition.keepsMinimumLifetime
      app = AppEntry(TerminalAppFacts.read(for: definition))
    } // End of init(_:)
  } // End of struct DefinitionEntry

  /// A definition's app facts in the JSON.
  struct AppEntry: Encodable {
    /// Whether LaunchServices knows the app.
    let installed: Bool
    /// Its path, when installed.
    let path: String?
    /// Its version, when readable.
    let version: String?
    /// `meets`, `tooOld`, `unknown` or `notInstalled`.
    let minimumVersion: String
    /// Whether it runs now.
    let running: Bool
    /// `notNeeded` or the permission's kind.
    let automation: String
    /// The raw status, when read.
    let automationStatus: Int32?

    /// The entry for `facts`.
    init(_ facts: TerminalAppFacts) {
      installed = facts.installed
      path = facts.path
      version = facts.version
      minimumVersion = facts.versionCheck.rawValue
      running = facts.running
      automation = facts.automation.kind
      automationStatus = facts.automation.status
    }
  } // End of struct AppEntry

  /// One unusable file or folder in the JSON.
  struct ProblemEntry: Encodable {
    /// `builtIn` or `user`.
    let folder: String
    /// The file's (or folder's) name.
    let file: String
    /// The problem's code.
    let problem: String
    /// The plain explanation.
    let message: String

    /// The entry for `problem`.
    init(_ problem: TerminalDefinitionFileProblem) {
      folder = problem.folder.rawValue
      file = problem.fileName
      self.problem = problem.problem.code
      message = problem.message
    }
  } // End of struct ProblemEntry

  /// Paths as printed.
  enum PathText {
    /// `url`'s path without a trailing slash.
    static func of(_ url: URL) -> String { WorkspaceTerminalAppInspector.displayPath(url) }
  }
} // End of enum TerminalsCommand
