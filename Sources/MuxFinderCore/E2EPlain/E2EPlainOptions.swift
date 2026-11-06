import Foundation

/// Why `muxfinder-probe e2e-plain`'s arguments cannot be used: the message the probe prints
/// before its usage (exit 2). Nothing was read, created or contacted.
public struct E2EPlainUsageError: Error, Sendable, Hashable {
  /// What is wrong, in plain words.
  public let message: String

  /// A usage error saying `message`.
  public init(_ message: String) {
    self.message = message
  }
}

/// `muxfinder-probe e2e-plain`'s arguments (PLAN.md D38 *The plain runs (I-12c3b)*), parsed in
/// the core so the parsing is tested hermetically: `--terminal <id> --local | --ssh saturno-m4
/// [--builtin-directory <dir>] [--user-directory <dir>]`, or `--help` alone.
///
/// - `--terminal` is a terminal definition's id (`TerminalDefinition.isValidID(_:)`); `iterm2`
///   is refused, since iTerm2 has its own `e2e-*` runs. Whether the id names a loaded
///   definition is checked once the definitions are loaded (`definition(in:)`).
/// - `--ssh` takes only `saturno-m4`, the one remote host *Unattended-run rules* 3 allows.
/// - `--builtin-directory` and `--user-directory` say where definitions load from, as
///   `terminals list` takes them.
///
/// Every option at most once. Paths are kept as typed (the probe makes them absolute).
public struct E2EPlainOptions: Sendable, Hashable {
  /// The only SSH destination a run may use (*Unattended-run rules* 3).
  public static let remoteDestination = "saturno-m4"

  /// What the arguments ask for.
  public enum Request: Sendable, Hashable {
    /// `--help`: print the usage, contact nothing.
    case help
    /// Run with these options.
    case run(E2EPlainOptions)
  }

  /// Where the run's session lives.
  public enum Target: Sendable, Hashable {
    /// The default tmux server of This Mac.
    case local
    /// The default tmux server of the SSH destination (only `remoteDestination`).
    case ssh(destination: String)
  }

  /// The terminal definition's id.
  public var terminalID: String
  /// This Mac or the SSH destination.
  public var target: Target
  /// `--builtin-directory` as typed, if given.
  public var builtInDirectory: String?
  /// `--user-directory` as typed, if given.
  public var userDirectory: String?

  /// Options from their parts.
  public init(
    terminalID: String,
    target: Target,
    builtInDirectory: String? = nil,
    userDirectory: String? = nil
  ) {
    self.terminalID = terminalID
    self.target = target
    self.builtInDirectory = builtInDirectory
    self.userDirectory = userDirectory
  } // End of init(terminalID:target:builtInDirectory:userDirectory:)

  /// Parses `arguments` (those after `e2e-plain`).
  public static func parse(_ arguments: [String]) throws(E2EPlainUsageError) -> Request {
    if arguments.count == 1, ["--help", "-h", "help"].contains(arguments[0]) { return .help }
    var values: [String: String] = [:]
    var local = false
    var remaining = arguments[...]
    while let argument = remaining.popFirst() {
      switch argument {
      case "--local":
        guard !local, values["--ssh"] == nil else {
          throw E2EPlainUsageError("use either --local or --ssh")
        }
        local = true
      case "--ssh", "--terminal", "--builtin-directory", "--user-directory":
        guard argument != "--ssh" || !local else {
          throw E2EPlainUsageError("use either --local or --ssh")
        }
        guard values[argument] == nil else { throw E2EPlainUsageError("\(argument) given twice") }
        guard let value = remaining.popFirst(), !value.isEmpty else {
          throw E2EPlainUsageError("\(argument) needs a value")
        }
        values[argument] = value
      default:
        throw E2EPlainUsageError("unknown option")
      }
    } // End of loop over arguments
    return .run(try options(local: local, values: values))
  } // End of static func parse(_:)

  /// The options for parsed `values`, with the terminal's and the host's rules checked.
  static func options(
    local: Bool,
    values: [String: String]
  ) throws(E2EPlainUsageError) -> E2EPlainOptions {
    guard let terminalID = values["--terminal"] else {
      throw E2EPlainUsageError("--terminal is required")
    }
    guard terminalID != LaunchTerminalApp.iterm2Value else {
      throw E2EPlainUsageError(
        "--terminal iterm2 is not run here: iTerm2 has its own runs (e2e-local, e2e-remote, "
          + "e2e-bury, e2e-detach-others)")
    }
    guard TerminalDefinition.isValidID(terminalID) else {
      throw E2EPlainUsageError("--terminal needs a terminal definition's id, such as terminal")
    }
    let target: Target
    if let destination = values["--ssh"] {
      guard destination == remoteDestination else {
        throw E2EPlainUsageError(
          "--ssh takes only \(remoteDestination), the one remote host the runs may use")
      }
      target = .ssh(destination: destination)
    } else if local {
      target = .local
    } else {
      throw E2EPlainUsageError("use --local or --ssh \(remoteDestination)")
    }
    return E2EPlainOptions(
      terminalID: terminalID, target: target, builtInDirectory: values["--builtin-directory"],
      userDirectory: values["--user-directory"])
  } // End of static func options(local:values:)

  /// The host the run uses: "This Mac", or the remote host by its destination.
  public var host: HostConfig {
    switch target {
    case .local:
      return HostConfig(displayName: "This Mac", mode: .local)
    case .ssh(let destination):
      return HostConfig(displayName: "Remote host", mode: .ssh, sshDestination: destination)
    }
  }

  /// The arguments that ask for this run again, in a fixed order (directories single-quoted).
  public var arguments: [String] {
    var words = ["--terminal", terminalID]
    switch target {
    case .local: words.append("--local")
    case .ssh(let destination): words += ["--ssh", destination]
    }
    if let builtInDirectory {
      words += ["--builtin-directory", ShellQuoting.posixSingleQuote(builtInDirectory)]
    }
    if let userDirectory {
      words += ["--user-directory", ShellQuoting.posixSingleQuote(userDirectory)]
    }
    return words
  } // End of var arguments

  /// The run's name for its output: `e2e-plain --terminal <id> --local` or `--ssh`.
  public var runName: String {
    switch target {
    case .local: return "e2e-plain --terminal \(terminalID) --local"
    case .ssh: return "e2e-plain --terminal \(terminalID) --ssh"
    }
  }

  /// The exact command a person runs from the repository root when the run is owed to them
  /// (the gate refused: *Unattended-run rules* 8).
  public var owedCommand: String {
    (["swift", "run", "muxfinder-probe", "e2e-plain"] + arguments).joined(separator: " ")
  }

  /// The loaded definition with the run's terminal id, or the refusal naming how many
  /// definitions and problems the load had.
  public func definition(
    in catalog: TerminalDefinitionCatalog
  ) -> Result<LoadedTerminalDefinition, E2EPlainRefusal> {
    guard let loaded = catalog.definition(withID: terminalID) else {
      return .failure(
        .unknownDefinition(
          id: terminalID, loaded: catalog.definitions.count, problems: catalog.problems.count))
    }
    return .success(loaded)
  } // End of func definition(in:)
} // End of struct E2EPlainOptions

/// Why `e2e-plain` refused to run before anything was created, written, discovered or sent
/// (exit 2): the terminal id names no loaded definition, or *Unattended-run rules* 8's gate
/// (`PlainRunGate`) refused the app's facts.
public enum E2EPlainRefusal: Error, Sendable, Hashable {
  /// No loaded definition has the id.
  case unknownDefinition(id: String, loaded: Int, problems: Int)
  /// The gate refused.
  case gate(PlainRunGate.Refusal)

  /// The reason the probe prints.
  public var message: String {
    switch self {
    case .unknownDefinition(let id, let loaded, let problems):
      return "no usable terminal definition \(id) (\(loaded) loaded, \(problems) problems)"
    case .gate(let refusal):
      return refusal.message
    }
  } // End of var message
} // End of enum E2EPlainRefusal
