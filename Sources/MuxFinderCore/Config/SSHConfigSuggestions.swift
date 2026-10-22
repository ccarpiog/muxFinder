import Darwin
import Foundation

/// Host names from the user's `~/.ssh/config` and the files it includes, offered as SSH
/// destination suggestions only (PLAN.md D19). Read-only: it opens files for reading and
/// writes nothing, under `~/.ssh` or anywhere else. OpenSSH still resolves every name itself
/// when muxFinder connects; a suggestion is just text the user may pick.
///
/// Parsing follows OpenSSH's `readconf.c` closely enough for names:
/// - Keywords are case-insensitive and separated from their arguments by whitespace, by `=`,
///   or by both (`Host=a`, `Host = a`, `Host a`). Blank lines and lines starting with `#` are
///   ignored; an unquoted `#` at the start of a word ends the line. Arguments are split like
///   OpenSSH's `argv_split`: single or double quotes, and `\` escaping a quote, a backslash or
///   (outside quotes) a space. A line with an unterminated quote is skipped, as OpenSSH
///   rejects it.
/// - Every word of a `Host` line is a pattern. One containing `*` or `?`, or starting with `!`,
///   is left out, and so is one that `Validation.sshDestination` refuses (empty, whitespace,
///   control characters, a leading `-`).
/// - `Include` takes one or more paths, each a glob(3) pattern expanded in lexical order: `~/`
///   is the home directory, and a path that is neither absolute nor starts with `~` is
///   relative to `~/.ssh/`. `~user/` is not expanded (left out). Includes are followed
///   wherever they appear, inside `Host` and `Match` blocks too, as OpenSSH reads them there.
///   The user's config is depth 0 and an included file one more than its includer; files
///   deeper than `maximumIncludeDepth` (16, OpenSSH's limit) are not read. Each file (by
///   device and inode, links followed) is read at most once, which also ends include cycles.
/// - Missing or unreadable files, anything that is not a regular file, and files larger than
///   `maximumFileSize` are skipped. At most `maximumFileCount` files are read.
/// - Names are de-duplicated, in first-seen order.
public struct SSHConfigSuggestions: Sendable {
  /// The deepest include level read (the user's config is level 0), as in OpenSSH.
  public static let maximumIncludeDepth = 16
  /// The default per-file size cap, in bytes.
  public static let defaultMaximumFileSize = 1024 * 1024
  /// The most files read in one collection.
  public static let maximumFileCount = 256

  /// The home directory whose `.ssh/config` is read, and that `~` stands for.
  public let homeDirectory: URL
  /// Files larger than this many bytes are skipped.
  public let maximumFileSize: Int

  /// Suggestions from `homeDirectory`'s `.ssh/config` (the current user's home by default).
  public init(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    maximumFileSize: Int = SSHConfigSuggestions.defaultMaximumFileSize
  ) {
    self.homeDirectory = homeDirectory
    self.maximumFileSize = maximumFileSize
  }

  /// The home directory's path without a trailing slash.
  var homePath: String { PrivateStorage.path(of: homeDirectory) }

  /// The suggested host names, de-duplicated in first-seen order. Never throws: a file that
  /// cannot be read contributes nothing.
  public func hostNames() -> [String] {
    var traversal = Traversal()
    readFile(atPath: homePath + "/.ssh/config", depth: 0, traversal: &traversal)
    return traversal.names
  }

  // MARK: - Traversal

  /// The state of one collection.
  struct Traversal {
    /// The names found so far, in first-seen order.
    var names: [String] = []
    /// The same names, for de-duplication.
    var seenNames: Set<String> = []
    /// The files read so far, by device and inode.
    var readFiles: Set<FileIdentity> = []

    /// Adds `name` unless it was seen before.
    mutating func add(_ name: String) {
      if seenNames.insert(name).inserted { names.append(name) }
    }
  }

  /// A file's identity: its device and inode.
  struct FileIdentity: Hashable {
    /// `st_dev`.
    var device: Int32
    /// `st_ino`.
    var inode: UInt64
  }

  /// Reads the configuration file at `path` (links followed) at include depth `depth`, adding
  /// its host names and following its includes.
  func readFile(atPath path: String, depth: Int, traversal: inout Traversal) {
    guard depth <= Self.maximumIncludeDepth,
      traversal.readFiles.count < Self.maximumFileCount
    else { return }
    // O_NONBLOCK keeps a FIFO from blocking the open; it does not affect regular files.
    let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { return }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_size <= off_t(maximumFileSize),
      traversal.readFiles.insert(FileIdentity(device: info.st_dev, inode: info.st_ino)).inserted,
      let data = try? PrivateStorage.readAll(from: descriptor, limit: maximumFileSize)
    else {
      Darwin.close(descriptor)
      return
    }
    Darwin.close(descriptor)
    let text = String(decoding: data, as: UTF8.self)
    let lines = text.split(
      omittingEmptySubsequences: true,
      whereSeparator: { $0 == "\n" || $0 == "\r\n" }
    )
    for line in lines {
      guard let directive = Self.directive(in: line) else { continue }
      switch directive.keyword {
      case "host":
        for pattern in directive.arguments where Self.isSuggestion(pattern) {
          traversal.add(pattern)
        }
      case "include":
        for argument in directive.arguments {
          for included in includePaths(for: argument) {
            readFile(atPath: included, depth: depth + 1, traversal: &traversal)
          }
        }
      default:
        continue
      }
    } // End of loop over lines
  } // End of func readFile(atPath:depth:traversal:)

  /// Whether a `Host` pattern is offered: no `*` or `?`, no leading `!`, and a valid SSH
  /// destination.
  static func isSuggestion(_ pattern: String) -> Bool {
    guard !pattern.contains("*"), !pattern.contains("?"), !pattern.hasPrefix("!") else {
      return false
    }
    return (try? Validation.sshDestination(pattern)) != nil
  }

  /// The existing paths an `Include` argument names, in lexical order.
  func includePaths(for argument: String) -> [String] {
    let pattern: String
    if argument.isEmpty {
      return []
    } else if argument == "~" || argument.hasPrefix("~/") {
      pattern = Self.escapedForGlob(homePath) + argument.dropFirst()
    } else if argument.hasPrefix("~") {
      return []
    } else if argument.hasPrefix("/") {
      pattern = argument
    } else {
      pattern = Self.escapedForGlob(homePath) + "/.ssh/" + argument
    }
    return Self.glob(pattern)
  } // End of func includePaths(for:)

  /// `path` with glob(3)'s special characters escaped, so a home directory is matched
  /// literally.
  static func escapedForGlob(_ path: String) -> String {
    var escaped = ""
    for character in path {
      if "\\*?[".contains(character) { escaped.append("\\") }
      escaped.append(character)
    }
    return escaped
  }

  /// The paths matching `pattern`, sorted (glob(3)'s default), or none.
  static func glob(_ pattern: String) -> [String] {
    var result = glob_t()
    defer { globfree(&result) }
    guard Darwin.glob(pattern, 0, nil, &result) == 0, let paths = result.gl_pathv else {
      return []
    }
    return (0..<Int(result.gl_pathc)).compactMap { index in
      paths[index].map { String(cString: $0) }
    }
  } // End of func glob(_:)

  // MARK: - Lines

  /// One configuration line's keyword (lowercased) and arguments.
  struct Directive: Equatable {
    /// The keyword, lowercased.
    var keyword: String
    /// The arguments, unquoted.
    var arguments: [String]
  }

  /// Splits a line into its keyword and arguments, or returns `nil` for a blank line, a
  /// comment, a line without a keyword, or one with an unterminated quote.
  static func directive(in line: Substring) -> Directive? {
    var scalars = Array(line.unicodeScalars)
    while let last = scalars.last, isLineWhitespace(last) || last == "\u{0C}" {
      scalars.removeLast()
    }
    var index = 0
    while index < scalars.count, isLineWhitespace(scalars[index]) { index += 1 }
    guard index < scalars.count, scalars[index] != "#" else { return nil }
    var keyword = String.UnicodeScalarView()
    while index < scalars.count, !isLineWhitespace(scalars[index]), scalars[index] != "=" {
      keyword.append(scalars[index])
      index += 1
    }
    // The separator: whitespace, at most one `=`, whitespace.
    while index < scalars.count, isLineWhitespace(scalars[index]) { index += 1 }
    if index < scalars.count, scalars[index] == "=" {
      index += 1
      while index < scalars.count, isLineWhitespace(scalars[index]) { index += 1 }
    }
    guard !keyword.isEmpty, let arguments = splitArguments(scalars[index...]) else {
      return nil
    }
    return Directive(keyword: String(keyword).lowercased(), arguments: arguments)
  } // End of func directive(in:)

  /// Splits arguments like OpenSSH's `argv_split` with comments ending the line. Returns `nil`
  /// for an unterminated quote.
  static func splitArguments(_ scalars: ArraySlice<Unicode.Scalar>) -> [String]? {
    var arguments: [String] = []
    var index = scalars.startIndex
    while index < scalars.endIndex {
      if scalars[index] == " " || scalars[index] == "\t" {
        index += 1
        continue
      }
      if scalars[index] == "#" { break }
      var quote: Unicode.Scalar?
      var argument = String.UnicodeScalarView()
      while index < scalars.endIndex {
        let current = scalars[index]
        let next = index + 1 < scalars.endIndex ? scalars[index + 1] : nil
        if current == "\\", let next,
          next == "'" || next == "\"" || next == "\\" || (quote == nil && next == " ")
        {
          argument.append(next)
          index += 1
        } else if quote == nil, current == " " || current == "\t" {
          break
        } else if quote == nil, current == "\"" || current == "'" {
          quote = current
        } else if let open = quote, current == open {
          quote = nil
        } else {
          argument.append(current)
        }
        index += 1
      } // End of loop over one argument's characters
      guard quote == nil else { return nil }
      arguments.append(String(argument))
    } // End of loop over arguments
    return arguments
  } // End of func splitArguments(_:)

  /// OpenSSH's whitespace for keywords: space, tab, carriage return and line feed.
  static func isLineWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    scalar == " " || scalar == "\t" || scalar == "\r" || scalar == "\n"
  }
}
