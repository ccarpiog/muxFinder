import Foundation
import MuxFinderCore

/// `muxfinder-probe hosts …`: read-only checks of the host configuration (PLAN.md D19).
///
/// `show` loads the host list through `HostStore.load()`, which never writes, and `suggestions`
/// reads `~/.ssh/config` through `SSHConfigSuggestions`. Neither creates muxFinder's folder or
/// any file, runs ssh or talks to iTerm2. Output is JSON on stdout; on failure a one-line error
/// goes to stderr and the exit status is non-zero.
enum HostsCommand {
  /// Usage lines for this subcommand group.
  static let usage = """
      hosts show [--config <path>]
          Load the host list without writing anything and print it as JSON with its state:
          saved, notSavedYet (the onboarding defaults are shown) or invalid (with the
          problem; the defaults are shown and the file is left as it is).
          --config  Read this file instead of
                    ~/Library/Application Support/muxFinder/hosts.json. Its folder must
                    belong to you and must not be a symbolic link.
      hosts suggestions
          Print the Host names from ~/.ssh/config and the files it includes as JSON
          (patterns with * or ?, negations and invalid destinations left out). Read-only.
    """

  /// Runs the subcommand named by the first argument and returns the exit status.
  static func run(_ arguments: [String]) async -> Int32 {
    switch arguments.first {
    case "show":
      return await runShow(Array(arguments.dropFirst()))
    case "suggestions":
      guard arguments.count == 1 else { return usageError("hosts suggestions takes no options") }
      return printJSON(SuggestionsOutput(suggestions: SSHConfigSuggestions().hostNames()))
    default:
      return usageError("unknown hosts subcommand")
    }
  } // End of func run(_:)

  /// `show`: loads the list and prints it with its state.
  static func runShow(_ arguments: [String]) async -> Int32 {
    var store = HostStore()
    var remaining = arguments[...]
    while let argument = remaining.popFirst() {
      guard argument == "--config", let path = remaining.popFirst(), !path.isEmpty else {
        return usageError("unknown option or missing value")
      }
      store = HostStore(fileURL: URL(fileURLWithPath: path).standardizedFileURL)
    }
    do {
      let result = try await store.load()
      return printJSON(ShowOutput(result, file: store.fileURL))
    } catch {
      printError("muxfinder-probe: \(error.localizedDescription)")
      return EX_SOFTWARE
    }
  } // End of func runShow(_:)

  /// Prints a usage error and returns `EX_USAGE`.
  static func usageError(_ message: String) -> Int32 {
    printError("muxfinder-probe: \(message)\n\nusage:\n\(usage)")
    return EX_USAGE
  }

  /// Prints `value` as pretty, sorted JSON and returns 0, or `EX_SOFTWARE` if it cannot be
  /// encoded.
  static func printJSON<Value: Encodable>(_ value: Value) -> Int32 {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else {
      printError("muxfinder-probe: could not encode the output")
      return EX_SOFTWARE
    }
    print(String(decoding: data, as: UTF8.self))
    return 0
  }

  /// The JSON printed by `show`.
  struct ShowOutput: Encodable {
    /// The file that was read.
    let file: String
    /// `saved`, `notSavedYet` or `invalid`.
    let state: String
    /// The problem's code when `invalid` (`notJSON`, `unsafe.extendedACL`, …).
    let problem: String?
    /// The problem's explanation when `invalid`.
    let reason: String?
    /// The loaded list, or the onboarding defaults.
    let hosts: [HostConfig]
    /// The id of This Mac, if one is chosen.
    let thisMac: UUID?

    /// The output for `result`, read from `file`.
    init(_ result: HostStoreLoadResult, file: URL) {
      self.file = file.path(percentEncoded: false)
      switch result.state {
      case .saved:
        state = "saved"
        problem = nil
        reason = nil
      case .notSavedYet:
        state = "notSavedYet"
        problem = nil
        reason = nil
      case .invalid(let found):
        state = "invalid"
        problem = found.code
        reason = found.message
      }
      hosts = result.hosts.hosts
      thisMac = result.hosts.thisMac?.id
    } // End of init(_:file:)
  }

  /// The JSON printed by `suggestions`.
  struct SuggestionsOutput: Encodable {
    /// The host names, in first-seen order.
    let suggestions: [String]
  }
}
