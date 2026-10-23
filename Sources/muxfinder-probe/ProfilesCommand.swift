import Foundation
import MuxFinderCore

/// `muxfinder-probe profiles …`: read-only checks of the persistent work profiles (PLAN.md D26).
///
/// `show` loads the host list through `HostStore.load()` (which never writes) and prints the
/// dynamic profile document the app would install, without writing it anywhere. `hashes`
/// prints the read-only hash snapshot of iTerm2's other profiles (`ITerm2ProfileSnapshot`):
/// entry names, kinds and SHA-256 digests of `DynamicProfiles/*` except `muxFinder.json`, and
/// the count and digest of `New Bookmarks` from `/usr/bin/defaults export com.googlecode.iterm2
/// -`; never a profile's contents. Neither contacts iTerm2, runs ssh or writes a file.
enum ProfilesCommand {
  /// Usage lines for this subcommand group.
  static let usage = """
      profiles show [--config <path>] [--helper <path>]
          Load the host list without writing anything and print, as JSON, the dynamic
          profile document muxFinder would install as DynamicProfiles/muxFinder.json (one
          "Persistent work" profile per host whose persistent profile is on). Writes
          nothing and never contacts iTerm2.
          --config  Read this host list file instead of
                    ~/Library/Application Support/muxFinder/hosts.json (as for hosts show).
          --helper  Use this helper path in the profiles' Command instead of the
                    muxfinder-launch next to this executable; a path iTerm2 could not split
                    into exactly three arguments is refused.
      profiles hashes [--directory <path>]
          Print a read-only hash snapshot of iTerm2's other profiles as JSON: each entry of
          ~/Library/Application Support/iTerm2/DynamicProfiles except muxFinder.json (name,
          kind, SHA-256 of a file's bytes or a link's text) and the count and SHA-256 of a
          canonical form of New Bookmarks from defaults export com.googlecode.iterm2 -.
          Names and hashes only, never profile contents; writes nothing.
          --directory  Snapshot this folder instead of iTerm2's DynamicProfiles.
    """

  /// Runs the subcommand named by the first argument and returns the exit status.
  static func run(_ arguments: [String]) async -> Int32 {
    switch arguments.first {
    case "show":
      return await runShow(Array(arguments.dropFirst()))
    case "hashes":
      return await runHashes(Array(arguments.dropFirst()))
    default:
      return usageError("unknown profiles subcommand")
    }
  }

  /// `show`: loads the list and prints the document.
  static func runShow(_ arguments: [String]) async -> Int32 {
    var store = HostStore()
    var helperPath: String?
    var remaining = arguments[...]
    while let option = remaining.popFirst() {
      guard let value = remaining.popFirst(), !value.isEmpty else {
        return usageError("missing value for \(option)")
      }
      switch option {
      case "--config": store = HostStore(fileURL: URL(fileURLWithPath: value).standardizedFileURL)
      case "--helper": helperPath = value
      default: return usageError("unknown option \(option)")
      }
    } // End of loop over the options
    let path: String
    if let helperPath {
      path = helperPath
    } else {
      do throws(LaunchHelperPathError) {
        path = try LaunchHelperPath.locate().path
      } catch {
        printError("muxfinder-probe: \(error.message)")
        return EX_UNAVAILABLE
      }
    }
    let loaded: HostStoreLoadResult
    do {
      loaded = try await store.load()
    } catch {
      printError("muxfinder-probe: \(error.localizedDescription)")
      return EX_SOFTWARE
    }
    let document: PersistentProfileDocument
    do throws(PersistentProfileError) {
      document = try PersistentProfiles.document(for: loaded.hosts, helperPath: path)
    } catch {
      printError("muxfinder-probe: \(error.message)")
      return EX_DATAERR
    }
    return printJSON(ShowOutput(loaded, file: store.fileURL, document: document))
  } // End of func runShow(_:)

  /// `hashes`: takes the snapshot and prints it.
  static func runHashes(_ arguments: [String]) async -> Int32 {
    var snapshotter = ITerm2ProfileSnapshotter()
    var remaining = arguments[...]
    while let option = remaining.popFirst() {
      guard option == "--directory", let value = remaining.popFirst(), !value.isEmpty else {
        return usageError("unknown option or missing value")
      }
      snapshotter.directory = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
    }
    do {
      return printJSON(try await snapshotter.snapshot())
    } catch {
      printError("muxfinder-probe: \(error)")
      return EX_SOFTWARE
    }
  } // End of func runHashes(_:)

  /// Prints a usage error and returns `EX_USAGE`.
  static func usageError(_ message: String) -> Int32 {
    printError("muxfinder-probe: \(message)\n\nusage:\n\(usage)")
    return EX_USAGE
  }

  /// Prints `value` as pretty, sorted JSON and returns 0, or `EX_SOFTWARE`.
  static func printJSON<Value: Encodable>(_ value: Value) -> Int32 {
    HostsCommand.printJSON(value)
  }

  /// The JSON printed by `show`.
  struct ShowOutput: Encodable {
    /// The host list file that was read.
    let file: String
    /// Its state: `saved`, `notSavedYet` or `invalid` (then the onboarding defaults, which have
    /// no profile, are used).
    let state: String
    /// The file name the document would be installed as.
    let fileName: String
    /// How many profiles the document holds.
    let count: Int
    /// The document as it would be written: `{"Profiles": […]}` with iTerm2's keys.
    let document: [String: [PersistentProfile]]

    /// The output for a load and its document.
    init(_ loaded: HostStoreLoadResult, file: URL, document: PersistentProfileDocument) {
      self.file = file.path(percentEncoded: false)
      switch loaded.state {
      case .saved: state = "saved"
      case .notSavedYet: state = "notSavedYet"
      case .invalid(let problem): state = "invalid." + problem.code
      }
      fileName = PersistentProfiles.fileName
      count = document.profiles.count
      self.document = ["Profiles": document.profiles]
    } // End of init(_:file:document:)
  }
}
