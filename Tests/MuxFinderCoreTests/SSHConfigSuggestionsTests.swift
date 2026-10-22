import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// Tests for `SSHConfigSuggestions`. Each test builds a synthetic home directory in a private
/// temporary folder; the user's `~/.ssh` is never read. Every host name is synthetic.
@Suite("SSH config suggestions")
struct SSHConfigSuggestionsTests {
  /// Creates a fresh synthetic home with an empty `.ssh` folder. The caller removes it.
  static func makeHome(named name: String = "home") throws -> URL {
    let base = try TestSupport.makeTemporaryDirectory()
    let home = base.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: home.appending(path: ".ssh", directoryHint: .isDirectory),
      withIntermediateDirectories: true
    )
    return home
  }

  /// Writes `text` to `path` (relative to `home`), creating missing folders.
  static func write(_ text: String, to path: String, in home: URL) throws {
    let url = home.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(text.utf8).write(to: url)
  }

  /// The names for a home whose `.ssh/config` is `config` and that holds `files` (paths
  /// relative to the home).
  static func names(
    _ config: String,
    files: [String: String] = [:],
    maximumFileSize: Int = SSHConfigSuggestions.defaultMaximumFileSize
  ) throws -> [String] {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    try write(config, to: ".ssh/config", in: home)
    for (path, text) in files { try write(text, to: path, in: home) }
    return SSHConfigSuggestions(homeDirectory: home, maximumFileSize: maximumFileSize)
      .hostNames()
  }

  /// Every word of a `Host` line is a pattern; names come in file order.
  @Test func collectsHostPatterns() throws {
    #expect(try Self.names("Host alpha beta\nHost gamma\n") == ["alpha", "beta", "gamma"])
  }

  /// Keywords are case-insensitive and take their arguments after whitespace, `=` or both;
  /// other keywords that start with "Host" are not `Host`.
  @Test func readsEveryKeywordForm() throws {
    let config = """
      HOST upper
      host lower
      hOsT mixed
      Host=equals
      Host = spaced-equals
      Host =left
      Host= right
      \tHost\ttabbed
         Host   indented
      Host\t=\ttab-equals
      Hostname not-a-host
      HostKeyAlias not-either
      =orphan
      Host
      """
    #expect(
      try Self.names(config) == [
        "upper", "lower", "mixed", "equals", "spaced-equals", "left", "right", "tabbed",
        "indented", "tab-equals",
      ]
    )
  } // End of func readsEveryKeywordForm()

  /// Single and double quotes group a word and are removed; `\` escapes a quote; a quoted
  /// word with a space is no valid destination; a line with an unterminated quote is skipped.
  @Test func unquotesValues() throws {
    let config = #"""
      Host "double-quoted" 'single-quoted'
      Host "with space" ok-after
      Host mixed"quote"d
      Host esc\"aped
      Host "unterminated
      Host after-bad
      """#
    #expect(
      try Self.names(config) == [
        "double-quoted", "single-quoted", "ok-after", "mixedquoted", #"esc"aped"#, "after-bad",
      ]
    )
  } // End of func unquotesValues()

  /// Comment lines are skipped, and an unquoted `#` at the start of a word ends the line; a
  /// `#` inside a word or a quote is kept.
  @Test func skipsComments() throws {
    let config = """
      # Host commented
         # Host indented-comment
      #Host no-space
      Host kept # trailing comment
      Host also#kept '#quoted-hash' #rest
      """
    #expect(try Self.names(config) == ["kept", "also#kept", "#quoted-hash"])
  }

  /// Patterns with `*` or `?`, negations, and words that are no valid SSH destination (a
  /// leading `-`) are left out; other characters are kept.
  @Test func excludesWildcardsAndNegations() throws {
    let config = """
      Host *
      Host *.example.test
      Host web? db??
      Host !negated
      Host lambda *.x !mu nu
      Host -oProxyCommand=evil
      Host bracket[1] user@direct.example.test
      """
    #expect(
      try Self.names(config) == ["lambda", "nu", "bracket[1]", "user@direct.example.test"]
    )
  } // End of func excludesWildcardsAndNegations()

  /// `Include` with a glob relative to `~/.ssh/` reads the matches in lexical order, at the
  /// place of the `Include`.
  @Test func followsGlobIncludesInOrder() throws {
    let names = try Self.names(
      "Host first\nInclude config.d/*\nHost last\n",
      files: [
        ".ssh/config.d/b.conf": "Host from-b\n",
        ".ssh/config.d/a.conf": "Host from-a\n",
        ".ssh/config.d/c.txt": "Host from-c\n",
      ]
    )
    #expect(names == ["first", "from-a", "from-b", "from-c", "last"])
  } // End of func followsGlobIncludesInOrder()

  /// `~/` is the home directory, absolute paths are used as they are, a line may name several
  /// paths, and the keyword forms apply to `Include` too.
  @Test func followsHomeAbsoluteAndSeveralIncludes() throws {
    let home = try Self.makeHome()
    defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    let absolute = home.appending(path: "elsewhere/two.conf").path(percentEncoded: false)
    try Self.write(
      "Include ~/custom/one.conf \(absolute)\ninclude   three.conf\nINCLUDE=four.conf\n",
      to: ".ssh/config",
      in: home
    )
    try Self.write("Host one\n", to: "custom/one.conf", in: home)
    try Self.write("Host two\n", to: "elsewhere/two.conf", in: home)
    try Self.write("Host three\n", to: ".ssh/three.conf", in: home)
    try Self.write("Host four\n", to: ".ssh/four.conf", in: home)
    #expect(
      SSHConfigSuggestions(homeDirectory: home).hostNames() == ["one", "two", "three", "four"]
    )
  } // End of func followsHomeAbsoluteAndSeveralIncludes()

  /// A home directory whose path holds glob characters is matched literally.
  @Test func escapesTheHomeDirectoryForGlob() throws {
    let home = try Self.makeHome(named: "home [x] *?")
    defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    try Self.write("Include ~/inc/*.conf extra.conf\n", to: ".ssh/config", in: home)
    try Self.write("Host from-inc\n", to: "inc/a.conf", in: home)
    try Self.write("Host from-extra\n", to: ".ssh/extra.conf", in: home)
    #expect(SSHConfigSuggestions(homeDirectory: home).hostNames() == ["from-inc", "from-extra"])
  }

  /// Includes nest up to OpenSSH's depth limit, 16 below the user's config; deeper files are
  /// not read.
  @Test func stopsAtTheIncludeDepthLimit() throws {
    var files: [String: String] = [:]
    for level in 1...20 {
      files[".ssh/level\(level).conf"] = "Host depth\(level)\nInclude level\(level + 1).conf\n"
    }
    let names = try Self.names("Host depth0\nInclude level1.conf\n", files: files)
    #expect(names == (0...16).map { "depth\($0)" })
    #expect(SSHConfigSuggestions.maximumIncludeDepth == 16)
  }

  /// Include cycles (a file including itself, two files including each other, a link to a
  /// file already read) end, and each name appears once.
  @Test func survivesIncludeCycles() throws {
    let home = try Self.makeHome()
    defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    try Self.write(
      "Host root\nInclude a.conf\nInclude config\nInclude a-link.conf\n",
      to: ".ssh/config",
      in: home
    )
    try Self.write("Host a\nInclude b.conf\n", to: ".ssh/a.conf", in: home)
    try Self.write("Host b\nInclude a.conf ~/.ssh/config\n", to: ".ssh/b.conf", in: home)
    try FileManager.default.createSymbolicLink(
      at: home.appending(path: ".ssh/a-link.conf"),
      withDestinationURL: home.appending(path: ".ssh/a.conf")
    )
    #expect(SSHConfigSuggestions(homeDirectory: home).hostNames() == ["root", "a", "b"])
  } // End of func survivesIncludeCycles()

  /// Missing files, globs that match nothing, unreadable files, folders and FIFOs are skipped
  /// (a FIFO without blocking), and reading goes on.
  @Test func skipsMissingAndUnreadableIncludes() throws {
    let home = try Self.makeHome()
    defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    try Self.write(
      "Include missing.conf nothing/*\nInclude locked.conf\nInclude folder.d fifo\nHost after\n",
      to: ".ssh/config",
      in: home
    )
    try Self.write("Host locked\n", to: ".ssh/locked.conf", in: home)
    let locked = home.appending(path: ".ssh/locked.conf").path(percentEncoded: false)
    try #require(chmod(locked, 0) == 0)
    try FileManager.default.createDirectory(
      at: home.appending(path: ".ssh/folder.d"),
      withIntermediateDirectories: false
    )
    try #require(mkfifo(home.appending(path: ".ssh/fifo").path(percentEncoded: false), 0o600) == 0)
    #expect(SSHConfigSuggestions(homeDirectory: home).hostNames() == ["after"])
  } // End of func skipsMissingAndUnreadableIncludes()

  /// `Include` inside a `Match` block (or a `Host` block) is still followed; `Match` lines
  /// give no names.
  @Test func followsIncludesInsideMatchBlocks() throws {
    let config = """
      Match host something exec "true"
        Include matched.conf
        Host inside-match
      Host block
        Include in-host.conf
      Match all
      Host after-match
      """
    let names = try Self.names(
      config,
      files: [".ssh/matched.conf": "Host from-match\n", ".ssh/in-host.conf": "Host from-host\n"]
    )
    #expect(names == ["from-match", "inside-match", "block", "from-host", "after-match"])
  } // End of func followsIncludesInsideMatchBlocks()

  /// A file larger than the size cap is skipped entirely; one exactly at the cap is read.
  @Test func capsFileSize() throws {
    let atCap = "Host at-cap\n" + String(repeating: "#", count: 51) + "\n"
    try #require(atCap.utf8.count == 64)
    let overCap = "Host over-cap\n" + String(repeating: "#", count: 50) + "\n"
    try #require(overCap.utf8.count == 65)
    let names = try Self.names(
      "Include over.conf at.conf\nHost small\n",
      files: [".ssh/over.conf": overCap, ".ssh/at.conf": atCap],
      maximumFileSize: 64
    )
    #expect(names == ["at-cap", "small"])
    #expect(
      try Self.names(String(repeating: " ", count: 65) + "\nHost x", maximumFileSize: 64) == [])
  } // End of func capsFileSize()

  /// Names are de-duplicated in first-seen order, across files too.
  @Test func deduplicatesInFirstSeenOrder() throws {
    let names = try Self.names(
      "Host b a\nHost a c b\nInclude dup.conf\n",
      files: [".ssh/dup.conf": "Host c d b\n"]
    )
    #expect(names == ["b", "a", "c", "d"])
  }

  /// No `~/.ssh/config`, or no `~/.ssh` at all, gives no names.
  @Test func missingConfigGivesNothing() throws {
    let home = try Self.makeHome()
    defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    #expect(SSHConfigSuggestions(homeDirectory: home).hostNames().isEmpty)
    try FileManager.default.removeItem(at: home.appending(path: ".ssh"))
    #expect(SSHConfigSuggestions(homeDirectory: home).hostNames().isEmpty)
  }

  /// CRLF line endings, trailing whitespace and form feeds are handled like OpenSSH.
  @Test func handlesLineEndings() throws {
    #expect(
      try Self.names("Host crlf-one\r\nHost crlf-two  \r\nHost feed\u{0C}\n")
        == ["crlf-one", "crlf-two", "feed"]
    )
  }

  /// `~user/` paths are not expanded, so no other user's configuration is read.
  @Test func ignoresOtherUsersHomes() throws {
    #expect(try Self.names("Include ~root/.ssh/config ~nobody/x\nHost mine\n") == ["mine"])
  }

  /// Collecting writes nothing: every file and folder under the home keeps its bytes, mode and
  /// modification time.
  @Test func writesNothing() throws {
    let home = try Self.makeHome()
    defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    try Self.write("Host a\nInclude config.d/*\n", to: ".ssh/config", in: home)
    try Self.write("Host b\n", to: ".ssh/config.d/b.conf", in: home)
    let before = try Self.tree(home)
    #expect(SSHConfigSuggestions(homeDirectory: home).hostNames() == ["a", "b"])
    #expect(try Self.tree(home) == before)
  }

  /// Every path under `root` with its mode, modification time and (for files) bytes.
  static func tree(_ root: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    let paths = try FileManager.default.subpathsOfDirectory(
      atPath: root.path(percentEncoded: false))
    for path in [""] + paths {
      let url = root.appending(path: path)
      var info = stat()
      try #require(lstat(url.path(percentEncoded: false), &info) == 0)
      var entry = "\(info.st_mode) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
      if info.st_mode & S_IFMT == S_IFREG {
        entry += " " + (try Data(contentsOf: url)).base64EncodedString()
      }
      result[path] = entry
    } // End of loop over paths
    return result
  } // End of func tree(_:)

  /// The line splitter returns the keyword lowercased and the unquoted arguments, or `nil` for
  /// lines without a keyword.
  @Test func splitsDirectives() {
    typealias Directive = SSHConfigSuggestions.Directive
    #expect(
      SSHConfigSuggestions.directive(in: "  Host = a 'b c' \"d\"\\ e")
        == Directive(keyword: "host", arguments: ["a", "b c", "d e"])
    )
    #expect(SSHConfigSuggestions.directive(in: "Host") == Directive(keyword: "host", arguments: []))
    #expect(SSHConfigSuggestions.directive(in: "=x") == nil)
    #expect(SSHConfigSuggestions.directive(in: "   ") == nil)
    #expect(SSHConfigSuggestions.directive(in: "# Host a") == nil)
    #expect(SSHConfigSuggestions.directive(in: "Host 'open") == nil)
    #expect(
      SSHConfigSuggestions.directive(in: #"Host a\\b c\d"#)
        == Directive(keyword: "host", arguments: [#"a\b"#, #"c\d"#])
    )
  } // End of func splitsDirectives()
}
