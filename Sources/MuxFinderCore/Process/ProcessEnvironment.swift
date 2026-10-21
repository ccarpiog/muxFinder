import Foundation

/// Helpers that build the explicit environment a `ProcessRequest` needs.
///
/// GUI apps start with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, which misses Homebrew. Local runs
/// add the Homebrew directories so tools such as tmux resolve the way they do in a terminal.
/// Code that needs a specific tool still passes its absolute path (PLAN.md D5).
public enum ProcessEnvironment {
  /// The macOS default search path for GUI and noninteractive processes.
  public static let systemSearchPath = "/usr/bin:/bin:/usr/sbin:/sbin"

  /// Homebrew directories added for local runs, in priority order (Apple Silicon first).
  public static let homebrewDirectories = [
    "/opt/homebrew/bin",
    "/opt/homebrew/sbin",
    "/usr/local/bin",
    "/usr/local/sbin",
  ]

  /// Returns `path` with every missing Homebrew directory prepended, keeping the existing
  /// entries and their order. A `nil` or empty path starts from `systemSearchPath`.
  public static func searchPathAddingHomebrew(to path: String?) -> String {
    let base = path.flatMap { $0.isEmpty ? nil : $0 } ?? systemSearchPath
    let existing = base.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
    let missing = homebrewDirectories.filter { !existing.contains($0) }
    return (missing + existing).joined(separator: ":")
  }

  /// Returns `environment` with `PATH` extended by `searchPathAddingHomebrew(to:)`.
  public static func addingHomebrewToSearchPath(
    _ environment: [String: String]
  ) -> [String: String] {
    var result = environment
    result["PATH"] = searchPathAddingHomebrew(to: environment["PATH"])
    return result
  }

  /// The environment for a local run: this process's environment plus the Homebrew
  /// directories on `PATH`.
  public static func local(
    base: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    addingHomebrewToSearchPath(base)
  }
}
