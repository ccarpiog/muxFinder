import Testing

@testable import MuxFinderCore

/// Tests for the environment helpers that add Homebrew to `PATH`.
@Suite("Process environment")
struct ProcessEnvironmentTests {
  /// The GUI default path gains every Homebrew directory in front.
  @Test func prependsHomebrewToTheSystemPath() {
    let path = ProcessEnvironment.searchPathAddingHomebrew(to: "/usr/bin:/bin:/usr/sbin:/sbin")
    #expect(
      path
        == "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:"
        + "/usr/bin:/bin:/usr/sbin:/sbin"
    )
  }

  /// Directories already present keep their position and are not duplicated.
  @Test func keepsExistingEntriesWithoutDuplicates() {
    let path = ProcessEnvironment.searchPathAddingHomebrew(
      to: "/usr/local/bin:/usr/bin:/opt/homebrew/bin"
    )
    #expect(path == "/opt/homebrew/sbin:/usr/local/sbin:/usr/local/bin:/usr/bin:/opt/homebrew/bin")
  }

  /// A missing or empty `PATH` starts from the system default.
  @Test(arguments: [nil, ""] as [String?])
  func startsFromTheSystemPathWhenUnset(path: String?) {
    let result = ProcessEnvironment.searchPathAddingHomebrew(to: path)
    #expect(result.hasSuffix(":" + ProcessEnvironment.systemSearchPath))
    #expect(result.hasPrefix("/opt/homebrew/bin:"))
  }

  /// Only `PATH` changes; every other variable is kept.
  @Test func changesOnlyThePath() {
    let base = ["HOME": "/Users/test", "LANG": "en_US.UTF-8"]
    let environment = ProcessEnvironment.local(base: base)
    #expect(environment["HOME"] == "/Users/test")
    #expect(environment["LANG"] == "en_US.UTF-8")
    #expect(environment["PATH"] == ProcessEnvironment.searchPathAddingHomebrew(to: nil))
    #expect(environment.count == 3)
  }
}
