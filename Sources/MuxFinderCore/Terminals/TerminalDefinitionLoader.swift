import Darwin
import Foundation

/// Where a loaded terminal definition came from.
public enum TerminalDefinitionSource: String, Sendable, Hashable, CaseIterable {
  /// Shipped with muxFinder and not overridden.
  case builtIn
  /// A user definition with an id no built-in has.
  case user
  /// A user definition that replaces the built-in with its id.
  case userOverride
}

/// Which folder a definition file was read from.
public enum TerminalDefinitionFolder: String, Sendable, Hashable {
  /// muxFinder's own definitions (the bundle's `Contents/Resources/Terminals/`).
  case builtIn
  /// The user's (`~/Library/Application Support/muxFinder/terminals/`).
  case user
}

/// An AppleScript file's text, read by the loader under its file rules. A runner compiles it
/// as it is (`AppleScriptRunning`); no value is ever inserted into it.
public struct TerminalScript: Sendable, Hashable {
  /// The file's name in the definition's folder.
  public let name: String
  /// The file's text.
  public let source: String

  /// A script named `name` with `source`.
  public init(name: String, source: String) {
    self.name = name
    self.source = source
  }
}

/// A usable definition, with where it came from and, for `appleScript` opens, its script.
public struct LoadedTerminalDefinition: Sendable, Hashable {
  /// The definition.
  public let definition: TerminalDefinition
  /// Built-in, user, or a user override of a built-in.
  public let source: TerminalDefinitionSource
  /// The definition file's name.
  public let fileName: String
  /// The script, for an `appleScript` open; `nil` for `exec`.
  public let script: TerminalScript?
}

/// A file (or folder) that could not be used, and why.
public struct TerminalDefinitionFileProblem: Sendable, Hashable {
  /// The folder it is in.
  public let folder: TerminalDefinitionFolder
  /// The last component of its path (the folder's own name for a folder problem).
  public let fileName: String
  /// Why it is not used.
  public let problem: TerminalDefinitionProblem

  /// The plain explanation.
  public var message: String { problem.message }
}

/// The result of one load: the usable definitions, sorted by id, and every problem.
public struct TerminalDefinitionCatalog: Sendable, Hashable {
  /// The usable definitions, sorted by id.
  public let definitions: [LoadedTerminalDefinition]
  /// Every unusable file or folder, built-in folder first, then by file name.
  public let problems: [TerminalDefinitionFileProblem]

  /// The definition with `id`, if any.
  public func definition(withID id: String) -> LoadedTerminalDefinition? {
    definitions.first { $0.definition.id == id }
  }
}

/// Loads terminal definitions (PLAN.md D38, Phase I-12b1) from muxFinder's built-in folder and
/// the user's folder. It only reads: it never creates, changes or removes a file or folder.
///
/// - **Built-ins** come from a folder passed in: the bundle's `Contents/Resources/Terminals/`
///   (`bundledDirectory(of:)`), sealed by the app's signature, or the repository's
///   `Resources/Terminals/` or a test folder in checks. Each file is opened without following
///   a link and must be a regular file within the size limits.
/// - **User definitions** come from `~/Library/Application Support/muxFinder/terminals/`
///   (`AppPaths.terminalDefinitionsDirectory`), under D19's rules, since a definition can make
///   muxFinder run a program: the folder is reached from `/` without passing a symbolic link,
///   is the user's, has mode 0700 and no extended ACL; each file is opened without following
///   links, is a regular file of the user's, not group- or world-writable, with no extended
///   ACL. A missing user folder is no problem; an unsafe one makes all of its definitions
///   unusable with one problem.
/// - **Limits:** a definition file at most 64 KiB, a script at most 256 KiB, at most 32
///   definition files (`*.json`, not hidden) per folder in name order; later ones are problems.
/// - **Ids:** two files of one folder with the same id are both refused. A user definition
///   overrides the built-in with its id (`userOverride`).
///
/// Every unusable file is kept with its problem and never stops the others.
public struct TerminalDefinitionLoader: Sendable {
  /// The largest definition file, in bytes.
  public static let maximumDefinitionFileSize = 64 * 1024
  /// The largest script file, in bytes.
  public static let maximumScriptFileSize = 256 * 1024
  /// The most definition files read from one folder.
  public static let maximumDefinitionFiles = 32
  /// The suffix of definition files.
  public static let definitionSuffix = ".json"
  /// The name of the built-in folder inside the bundle's resources.
  public static let bundledFolderName = "Terminals"

  /// The built-in folder, if any.
  public var builtInDirectory: URL?
  /// The user's folder, if any.
  public var userDirectory: URL?
  /// The user who must own the user folder and its files.
  public var owner: uid_t

  /// A loader for these folders; `owner` defaults to the effective user.
  public init(builtInDirectory: URL?, userDirectory: URL?, owner: uid_t = geteuid()) {
    self.builtInDirectory = builtInDirectory
    self.userDirectory = userDirectory
    self.owner = owner
  }

  /// The built-in folder inside `bundle`'s resources (`Contents/Resources/Terminals/`).
  public static func bundledDirectory(of bundle: Bundle = .main) -> URL? {
    bundle.resourceURL?.appending(path: bundledFolderName, directoryHint: .isDirectory)
  }

  /// Reads both folders and returns the usable definitions and every problem. Never throws
  /// and never writes.
  public func load() -> TerminalDefinitionCatalog {
    var problems: [TerminalDefinitionFileProblem] = []
    let builtIns = builtInDirectory.map { read($0, as: .builtIn, problems: &problems) } ?? []
    let users = userDirectory.map { read($0, as: .user, problems: &problems) } ?? []
    let builtInByID = Self.uniqueByID(builtIns, folder: .builtIn, problems: &problems)
    let userByID = Self.uniqueByID(users, folder: .user, problems: &problems)
    var definitions: [LoadedTerminalDefinition] = []
    for (id, candidate) in builtInByID where userByID[id] == nil {
      definitions.append(candidate.loaded(as: .builtIn))
    }
    for (id, candidate) in userByID {
      definitions.append(candidate.loaded(as: builtInByID[id] == nil ? .user : .userOverride))
    }
    definitions.sort { $0.definition.id < $1.definition.id }
    problems.sort { left, right in
      left.folder != right.folder ? left.folder == .builtIn : left.fileName < right.fileName
    }
    return TerminalDefinitionCatalog(definitions: definitions, problems: problems)
  } // End of func load()

  // MARK: - One folder

  /// A definition read from a file, before the id rules.
  struct Candidate {
    /// The file's name.
    let fileName: String
    /// The definition.
    let definition: TerminalDefinition
    /// Its script, for an `appleScript` open.
    let script: TerminalScript?

    /// The loaded definition with `source`.
    func loaded(as source: TerminalDefinitionSource) -> LoadedTerminalDefinition {
      LoadedTerminalDefinition(
        definition: definition, source: source, fileName: fileName, script: script)
    }
  } // End of struct Candidate

  /// Reads the definition files of the folder at `url`, adding a problem for each unusable
  /// one (or one for an unusable folder).
  func read(
    _ url: URL,
    as folder: TerminalDefinitionFolder,
    problems: inout [TerminalDefinitionFileProblem]
  ) -> [Candidate] {
    let path = PrivateStorage.path(of: url)
    let folderName = (path as NSString).lastPathComponent
    let opened =
      folder == .user
      ? Self.openUserFolder(atPath: path, owner: owner) : Self.openBuiltInFolder(atPath: path)
    let directory: Int32
    switch opened {
    case .opened(let descriptor):
      directory = descriptor
    case .missing:
      if folder == .builtIn {
        problems.append(
          .init(folder: folder, fileName: folderName, problem: .unsafeFolder(.missing)))
      }
      return []
    case .unsafe(let reason):
      problems.append(.init(folder: folder, fileName: folderName, problem: .unsafeFolder(reason)))
      return []
    }
    defer { Darwin.close(directory) }
    let names: [String]
    do throws(PrivateStorageError) {
      names = try PrivateStorage.entryNames(in: directory)
    } catch {
      problems.append(
        .init(folder: folder, fileName: folderName, problem: .unsafeFolder(.unreadable)))
      return []
    }
    let files = names.filter { $0.hasSuffix(Self.definitionSuffix) && !$0.hasPrefix(".") }.sorted()
    var candidates: [Candidate] = []
    for (index, name) in files.enumerated() {
      guard index < Self.maximumDefinitionFiles else {
        let problem = TerminalDefinitionProblem.tooManyFiles(limit: Self.maximumDefinitionFiles)
        problems.append(.init(folder: folder, fileName: name, problem: problem))
        continue
      }
      switch readCandidate(named: name, in: directory, folder: folder) {
      case .success(let candidate): candidates.append(candidate)
      case .failure(let problem):
        problems.append(.init(folder: folder, fileName: name, problem: problem))
      }
    } // End of loop over the folder's definition files
    return candidates
  } // End of func read(_:as:problems:)

  /// Reads and checks the definition file `name` in `directory` and, for an `appleScript`
  /// open, its script.
  func readCandidate(
    named name: String,
    in directory: Int32,
    folder: TerminalDefinitionFolder
  ) -> Result<Candidate, TerminalDefinitionProblem> {
    let fileOwner = folder == .user ? owner : nil
    let data: Data
    switch Self.readFile(
      named: name, in: directory, limit: Self.maximumDefinitionFileSize, owner: fileOwner)
    {
    case .contents(let bytes): data = bytes
    case .unusable(let reason): return .failure(.unsafeFile(reason))
    }
    let definition: TerminalDefinition
    do throws(TerminalDefinitionProblem) {
      definition = try TerminalDefinition.decode(data)
    } catch {
      return .failure(error)
    }
    guard case .appleScript(let scriptName, _) = definition.open else {
      return .success(Candidate(fileName: name, definition: definition, script: nil))
    }
    switch Self.readFile(
      named: scriptName, in: directory, limit: Self.maximumScriptFileSize, owner: fileOwner)
    {
    case .contents(let bytes):
      guard !bytes.contains(0), let source = String(data: bytes, encoding: .utf8) else {
        return .failure(.scriptNotText(name: scriptName))
      }
      let script = TerminalScript(name: scriptName, source: source)
      return .success(Candidate(fileName: name, definition: definition, script: script))
    case .unusable(let reason):
      return .failure(.unsafeScript(name: scriptName, reason))
    }
  } // End of func readCandidate(named:in:folder:)

  /// Keeps the candidates whose id no other candidate of the folder has; each one sharing an
  /// id gets a `duplicateID` problem.
  static func uniqueByID(
    _ candidates: [Candidate],
    folder: TerminalDefinitionFolder,
    problems: inout [TerminalDefinitionFileProblem]
  ) -> [String: Candidate] {
    let groups = Dictionary(grouping: candidates) { $0.definition.id }
    var unique: [String: Candidate] = [:]
    for (id, group) in groups {
      if group.count == 1 {
        unique[id] = group[0]
      } else {
        for candidate in group {
          problems.append(
            .init(folder: folder, fileName: candidate.fileName, problem: .duplicateID(id)))
        }
      }
    } // End of loop over the folder's ids
    return unique
  } // End of static func uniqueByID(_:folder:problems:)

  // MARK: - File system

  /// What opening a folder gave.
  enum FolderOpen {
    /// The folder's descriptor (the caller closes it).
    case opened(Int32)
    /// No folder.
    case missing
    /// A folder that must not be used.
    case unsafe(TerminalDefinitionProblem.FolderReason)
  }

  /// Opens the built-in folder: not a symbolic link itself, a folder. Its owner and mode are
  /// not checked (an app in `/Applications` may be root's, and its signature seals it).
  static func openBuiltInFolder(atPath path: String) -> FolderOpen {
    let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      let code = errno
      return code == ENOENT ? .missing : .unsafe(openFailure(code, at: path, in: AT_FDCWD))
    }
    return .opened(descriptor)
  } // End of static func openBuiltInFolder(atPath:)

  /// Why opening `name` in `directory` as a folder with `O_NOFOLLOW` failed with `code`.
  /// macOS answers a link with `ENOTDIR` (because of `O_DIRECTORY`) or `ELOOP`, so either is
  /// told apart by looking at the entry itself.
  static func openFailure(
    _ code: Int32,
    at name: String,
    in directory: Int32
  ) -> TerminalDefinitionProblem.FolderReason {
    guard code == ENOTDIR || code == ELOOP else { return .unreadable }
    var info = stat()
    guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return .unreadable }
    return info.st_mode & S_IFMT == S_IFLNK ? .symbolicLink : .notAFolder
  }

  /// Opens the user folder at the absolute `path` one component at a time from `/`, each
  /// with `O_NOFOLLOW`, so no symbolic link on the way is followed; then checks the folder
  /// itself: `owner`'s, mode exactly 0700, no extended ACL. A path that does not exist (even
  /// through a link) is `missing`; one that exists through a link is `unsafe(.symbolicLink)`.
  static func openUserFolder(atPath path: String, owner: uid_t) -> FolderOpen {
    guard path.hasPrefix("/") else { return .unsafe(.notAPlainPath) }
    let components = path.split(separator: "/").map(String.init)
    guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
      return .unsafe(.notAPlainPath)
    }
    var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard current >= 0 else { return .unsafe(.unreadable) }
    for (index, component) in components.enumerated() {
      var info = stat()
      guard fstatat(current, component, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
        let code = errno
        Darwin.close(current)
        return code == ENOENT || code == ENOTDIR ? .missing : .unsafe(.unreadable)
      }
      switch info.st_mode & S_IFMT {
      case S_IFDIR:
        break
      case S_IFLNK:
        Darwin.close(current)
        var target = stat()
        // Following links this time: only a path that leads somewhere is unsafe.
        return fstatat(AT_FDCWD, path, &target, 0) == 0 ? .unsafe(.symbolicLink) : .missing
      default:
        Darwin.close(current)
        return index == components.count - 1 ? .unsafe(.notAFolder) : .missing
      }
      let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard next >= 0 else {
        // The entry changed between the look and the open.
        let code = errno
        let reason = openFailure(code, at: component, in: current)
        Darwin.close(current)
        return code == ENOENT ? .missing : .unsafe(reason)
      }
      Darwin.close(current)
      current = next
    } // End of loop over the path's components
    if let reason = folderProblem(current, owner: owner) {
      Darwin.close(current)
      return .unsafe(reason)
    }
    return .opened(current)
  } // End of static func openUserFolder(atPath:owner:)

  /// The first reason not to use the open user folder, if any: not `owner`'s, mode not 0700,
  /// an extended ACL.
  static func folderProblem(
    _ descriptor: Int32,
    owner: uid_t
  ) -> TerminalDefinitionProblem.FolderReason? {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { return .unreadable }
    guard info.st_uid == owner else { return .notOwnedByUser }
    guard info.st_mode & 0o7777 == PrivateStorage.directoryPermissions else {
      return .permissionsNotPrivate
    }
    guard let hasACL = try? ExtendedACL.isPresent(on: descriptor) else { return .unreadable }
    return hasACL ? .extendedACL : nil
  }

  /// What reading a file gave.
  enum FileRead {
    /// Its bytes.
    case contents(Data)
    /// Why it is not used.
    case unusable(TerminalDefinitionProblem.FileReason)
  }

  /// Opens `name` in `directory` without following a link or blocking, and reads it if it is
  /// a regular file of at most `limit` bytes. With an `owner` (user files), it must also be
  /// that user's, not group- or world-writable, and carry no extended ACL. Never writes.
  static func readFile(
    named name: String,
    in directory: Int32,
    limit: Int,
    owner: uid_t?
  ) -> FileRead {
    // O_NONBLOCK keeps a FIFO from blocking the open; it does not affect regular files.
    let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
      switch errno {
      case ENOENT: return .unusable(.missing)
      case ELOOP: return .unusable(.symbolicLink)
      default: return .unusable(.unreadable)
      }
    }
    defer { Darwin.close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { return .unusable(.unreadable) }
    guard info.st_mode & S_IFMT == S_IFREG else { return .unusable(.notARegularFile) }
    if let owner {
      guard info.st_uid == owner else { return .unusable(.notOwnedByUser) }
      guard info.st_mode & 0o022 == 0 else { return .unusable(.writableByOthers) }
      guard let hasACL = try? ExtendedACL.isPresent(on: descriptor) else {
        return .unusable(.unreadable)
      }
      if hasACL { return .unusable(.extendedACL) }
    }
    guard info.st_size <= off_t(limit) else { return .unusable(.tooLarge) }
    do throws(PrivateStorageError) {
      return .contents(try PrivateStorage.readAll(from: descriptor, limit: limit))
    } catch .fileTooLarge {
      return .unusable(.tooLarge)
    } catch {
      return .unusable(.unreadable)
    }
  } // End of static func readFile(named:in:limit:owner:)
} // End of struct TerminalDefinitionLoader

extension AppPaths {
  /// The folder of the user's terminal definitions (PLAN.md D38),
  /// `<root>/terminals`. Nothing is created: the loader only reads it, and a missing folder is
  /// no problem.
  public var terminalDefinitionsDirectory: URL {
    applicationSupportDirectory.appending(path: "terminals", directoryHint: .isDirectory)
  }
}
