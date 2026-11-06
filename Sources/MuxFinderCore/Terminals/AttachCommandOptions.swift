import Foundation

/// Why `muxfinder-probe attach`'s arguments cannot be used: the message the probe prints before
/// its usage (exit 64). Nothing was contacted.
public struct AttachCommandUsageError: Error, Sendable, Hashable {
  /// What is wrong, in plain words.
  public let message: String

  /// A usage error saying `message`.
  public init(_ message: String) {
    self.message = message
  }
}

/// `muxfinder-probe attach`'s arguments (PLAN.md D38, Phase I-12c3a), parsed in the core so the
/// parsing is tested hermetically: `--local | --ssh <destination> --session <$id>
/// [--tmux-path <path>] [--profile <name>] [--terminal <id> [--builtin-directory <dir>]
/// [--user-directory <dir>]]`, or `--help` alone.
///
/// - `--terminal` is `iterm2` (today's path, also when absent) or a terminal definition's id
///   (`TerminalDefinition.isValidID(_:)`), which attaches through `PlainTerminalBackend`.
/// - `--builtin-directory` and `--user-directory` say where definitions load from, as
///   `terminals list` takes them; only with a plain `--terminal`.
/// - `--profile` is iTerm2's, so not with a plain `--terminal`.
///
/// Every option at most once. Paths are kept as typed (the probe makes them absolute).
public struct AttachCommandOptions: Sendable, Hashable {
  /// What the arguments ask for.
  public enum Request: Sendable, Hashable {
    /// `--help`: print the usage, contact nothing.
    case help
    /// Attach with these options.
    case attach(AttachCommandOptions)
  }

  /// The host: "This Mac", or the remote host by its destination (with the tmux override and,
  /// for iTerm2, the profile).
  public var host: HostConfig
  /// The session to attach.
  public var sessionID: TmuxSessionID
  /// The terminal: `.iterm2` (the default) or a plain definition's id.
  public var terminal: LaunchTerminalApp
  /// `--builtin-directory` as typed, if given.
  public var builtInDirectory: String?
  /// `--user-directory` as typed, if given.
  public var userDirectory: String?

  /// Options from their parts.
  public init(
    host: HostConfig,
    sessionID: TmuxSessionID,
    terminal: LaunchTerminalApp = .iterm2,
    builtInDirectory: String? = nil,
    userDirectory: String? = nil
  ) {
    self.host = host
    self.sessionID = sessionID
    self.terminal = terminal
    self.builtInDirectory = builtInDirectory
    self.userDirectory = userDirectory
  } // End of init(host:sessionID:terminal:builtInDirectory:userDirectory:)

  /// Parses `arguments` (those after `attach`).
  public static func parse(
    _ arguments: [String]
  ) throws(AttachCommandUsageError) -> Request {
    if arguments.count == 1, ["--help", "-h", "help"].contains(arguments[0]) { return .help }
    var values: [String: String] = [:]
    var mode: HostConfig.ConnectionMode?
    var remaining = arguments[...]
    while let argument = remaining.popFirst() {
      switch argument {
      case "--local":
        guard mode == nil else { throw AttachCommandUsageError("use either --local or --ssh") }
        mode = .local
      case "--ssh", "--session", "--tmux-path", "--profile", "--terminal", "--builtin-directory",
        "--user-directory":
        guard values[argument] == nil, argument != "--ssh" || mode == nil else {
          throw AttachCommandUsageError(
            argument == "--ssh" ? "use either --local or --ssh" : "\(argument) given twice")
        }
        guard let value = remaining.popFirst(), !value.isEmpty else {
          throw AttachCommandUsageError("\(argument) needs a value")
        }
        if argument == "--ssh" { mode = .ssh }
        values[argument] = value
      default:
        throw AttachCommandUsageError("unknown option")
      }
    } // End of loop over arguments
    guard let mode else { throw AttachCommandUsageError("use --local or --ssh") }
    guard let session = values["--session"] else {
      throw AttachCommandUsageError("--session is required")
    }
    guard let sessionID = TmuxSessionID(session) else {
      throw AttachCommandUsageError("--session needs an id such as '$3'")
    }
    return .attach(try options(mode: mode, sessionID: sessionID, values: values))
  } // End of static func parse(_:)

  /// The options for parsed `values`, with the terminal's rules checked.
  static func options(
    mode: HostConfig.ConnectionMode,
    sessionID: TmuxSessionID,
    values: [String: String]
  ) throws(AttachCommandUsageError) -> AttachCommandOptions {
    var terminal = LaunchTerminalApp.iterm2
    if let value = values["--terminal"] {
      guard let parsed = LaunchTerminalApp(value) else {
        throw AttachCommandUsageError("--terminal needs iterm2 or a terminal definition's id")
      }
      terminal = parsed
    }
    if terminal == .iterm2,
      values["--builtin-directory"] != nil || values["--user-directory"] != nil
    {
      throw AttachCommandUsageError(
        "--builtin-directory and --user-directory go with a --terminal other than iterm2")
    }
    if terminal != .iterm2, values["--profile"] != nil {
      throw AttachCommandUsageError("--profile is iTerm2's; leave it out with this --terminal")
    }
    let host = HostConfig(
      displayName: mode == .local ? "This Mac" : "Remote host", mode: mode,
      sshDestination: values["--ssh"] ?? "", tmuxPathOverride: values["--tmux-path"],
      iTermProfileName: values["--profile"])
    return AttachCommandOptions(
      host: host, sessionID: sessionID, terminal: terminal,
      builtInDirectory: values["--builtin-directory"], userDirectory: values["--user-directory"])
  } // End of static func options(mode:sessionID:values:)
} // End of struct AttachCommandOptions

/// How strictly a plain run guards its terminal app (PLAN.md D38, Phase I-12c3a review fix):
/// the policy the plain window layer (`PlainTerminalWindows`) enforces at its side-effect
/// boundary, and the plain backend asks it about before it writes a request.
public enum PlainRunPolicy: Sendable, Hashable {
  /// The app's: a person asked for the window, so an open may launch the app and an
  /// Automation prompt may show; only the window layer's own facts checks apply.
  case interactive
  /// *Unattended-run rules* 8 (`muxfinder-probe attach --terminal <id>`): `PlainRunGate` is
  /// checked again over facts read at that moment, right before the launch request is written
  /// and right before every Apple event or `exec` spawn; a refusal
  /// (`PlainTerminalWindowError.unattendedRunRefused`) writes, sends and launches nothing more,
  /// and the plain backend withdraws a request it wrote.
  case unattended
}

/// *Unattended-run rules* 8 for a real run of a plain terminal (PLAN.md D38, Phase I-12c3a):
/// never launch Terminal.app or Ghostty, and never send either an Apple event unless it is
/// already running and its Automation permission reads granted without a prompt. Checked over
/// facts read with nothing sent (`TerminalAppFacts`) before anything is written, opened or
/// sent; `muxfinder-probe attach --terminal <id>` refuses with exit 2 and the reason. The probe
/// checks it once before discovery and has the window layer check it again at every side
/// effect (`PlainRunPolicy.unattended`), since the app may quit or the permission change while
/// discovery runs.
public enum PlainRunGate {
  /// Why the run may not go ahead.
  public enum Refusal: Error, Sendable, Hashable {
    /// LaunchServices finds no app with the definition's bundle identifier.
    case notInstalled
    /// The installed version is below the definition's minimum, or cannot be read.
    case versionNotUsable(TerminalAppFacts.VersionCheck)
    /// The app is not running: opening a window would launch it.
    case notRunning
    /// The Automation permission does not read `granted` (an `appleScript` definition).
    case permissionNotGranted(AutomationPermission)

    /// A stable name: `notInstalled`, `versionNotUsable`, `notRunning` or
    /// `permissionNotGranted`.
    public var kind: String {
      switch self {
      case .notInstalled: return "notInstalled"
      case .versionNotUsable: return "versionNotUsable"
      case .notRunning: return "notRunning"
      case .permissionNotGranted: return "permissionNotGranted"
      }
    }

    /// The reason the probe prints.
    public var message: String {
      switch self {
      case .notInstalled:
        return "the terminal app is not installed"
      case .versionNotUsable(let check):
        return "the terminal app's version does not meet the definition's minimum "
          + "(\(check.rawValue))"
      case .notRunning:
        return "the terminal app is not running, and the run must never launch it "
          + "(Unattended-run rules 8); its real run is owed to the user"
      case .permissionNotGranted(let permission):
        return "the Automation permission for the terminal app reads \(permission.kind), not "
          + "granted (Unattended-run rules 8); its real run is owed to the user"
      }
    } // End of var message
  } // End of enum Refusal

  /// The refusal for `definition`'s app with `facts`, or `nil` when the run may go ahead: the
  /// app installed with a version meeting the minimum, running, and for an `appleScript`
  /// definition its permission `granted` (an `exec` one sends no Apple event, but still must
  /// not launch the app).
  public static func check(
    _ definition: TerminalDefinition,
    facts: TerminalAppFacts
  ) -> Refusal? {
    guard facts.installed, facts.versionCheck != .notInstalled else { return .notInstalled }
    guard facts.versionCheck == .meets else { return .versionNotUsable(facts.versionCheck) }
    guard facts.running else { return .notRunning }
    guard definition.needsAutomationPermission else { return nil }
    switch facts.automation {
    case .notNeeded:
      // Facts read for an `appleScript` definition always carry the permission; treat its
      // absence as not known, so nothing is sent.
      return .permissionNotGranted(.notDetermined)
    case .permission(let permission, _):
      return permission.allowsEventsWithoutPrompt ? nil : .permissionNotGranted(permission)
    }
  } // End of static func check(_:facts:)

  /// The refusal a plain attach ended with when its window layer's `unattended` policy refused
  /// it at a side effect (`terminalWindow(unattendedRunRefused)`: its request withdrawn,
  /// nothing sent or launched), or `nil`; the probe exits 2 with its reason then.
  public static func refusal(of result: AttachResult) -> Refusal? {
    guard case .terminalWindow(.unattendedRunRefused(_, let refusal))? = result.failure else {
      return nil
    }
    return refusal
  }
} // End of enum PlainRunGate
