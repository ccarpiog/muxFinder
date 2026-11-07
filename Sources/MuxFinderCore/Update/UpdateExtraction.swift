import Darwin
import Foundation

/// Why unpacking the zip failed (PLAN.md D39, I-13b1).
public enum UpdateExtractionFailure: Error, Sendable, Hashable {
  /// The fresh folder for the contents could not be created (this errno).
  case folderNotCreated(errno: Int32)
  /// The fresh folder for the contents could not be opened for the watchdog (this errno).
  case folderUnreadable(errno: Int32)
  /// The archive check refused the zip before `ditto` ran.
  case archive(UpdateArchiveProblem)
  /// What `ditto` wrote passed the bounds (`UpdateArchiveLimits`), so it was stopped (or had
  /// just ended).
  case expansionExceeded
  /// `ditto` could not be started.
  case notStarted
  /// `ditto` exited with this status.
  case exited(Int32)
  /// `ditto` was ended by this signal.
  case signaled(Int32)
  /// `ditto` ran past `UpdateExtractor.timeout` and was stopped.
  case timedOut
  /// The update was cancelled while `ditto` ran.
  case cancelled

  /// A stable, machine-readable name.
  public var code: String {
    switch self {
    case .folderNotCreated(let code): return "folderNotCreated.\(code)"
    case .folderUnreadable(let code): return "folderUnreadable.\(code)"
    case .archive(let problem): return "archive.\(problem.code)"
    case .expansionExceeded: return "expansionExceeded"
    case .notStarted: return "notStarted"
    case .exited(let status): return "exited.\(status)"
    case .signaled(let signal): return "signaled.\(signal)"
    case .timedOut: return "timedOut"
    case .cancelled: return "cancelled"
    }
  } // End of var code

  /// The reason, as a phrase after "Couldn't update: ".
  public var reason: String {
    switch self {
    case .cancelled: return "the update was cancelled"
    case .timedOut: return "unpacking the download took too long"
    case .archive(let problem): return problem.reason
    case .expansionExceeded: return "the download would be too large unpacked"
    default: return "the download couldn't be unpacked"
    }
  } // End of var reason
}

/// Unpacks the downloaded zip with `/usr/bin/ditto -x -k <zip> <folder>` (PLAN.md D39,
/// I-13b1): an argv array through the project's `ProcessRunner`, never a shell, with only
/// `PATH` in its environment and a time bound. `ditto` turns the zip's `._` AppleDouble
/// entries into extended attributes, keeps `..` components and absolute names inside the
/// destination, writes a FIFO or socket entry as an empty regular file, takes each entry's
/// name from its local header, unpacks entries no directory record lists, and writes as many
/// bytes as a deflate stream holds whatever size the directory declares (all checked on this
/// Mac); the shape check (`UpdateBundleShape`) then decides what was unpacked.
///
/// Before `ditto` runs, the archive check (`UpdateArchiveCheck`) reads the zip's directory and
/// local headers and refuses it when it declares too much or is not what it seems. While
/// `ditto` runs, a watchdog measures the destination every `watchInterval`
/// (`UpdateExpansionWatch`) and, once it passes the bounds, cancels the run, which stops
/// `ditto`'s process group the runner's way (SIGTERM, then SIGKILL after its grace period) and
/// waits for it; the destination is measured once more when `ditto` ends. The caller deletes
/// the partial contents.
public struct UpdateExtractor: Sendable {
  /// `ditto`.
  public static let dittoURL = URL(fileURLWithPath: "/usr/bin/ditto")
  /// The longest `ditto` may run.
  public static let timeout: Duration = .seconds(120)
  /// How often the watchdog measures what `ditto` has written.
  public static let watchInterval: Duration = .milliseconds(50)

  /// Runs `ditto`.
  let runner: any ProcessRunner
  /// The archive check's and the watchdog's bounds.
  let limits: UpdateArchiveLimits
  /// How often the watchdog measures.
  let watchInterval: Duration

  /// An extractor running `ditto` through `runner`, within `limits`.
  public init(
    runner: any ProcessRunner = PosixSpawnProcessRunner(),
    limits: UpdateArchiveLimits = .standard,
    watchInterval: Duration = UpdateExtractor.watchInterval
  ) {
    self.runner = runner
    self.limits = limits
    self.watchInterval = watchInterval
  }

  /// The argv after `ditto`'s own path.
  public static func arguments(zip: String, destination: String) -> [String] {
    ["-x", "-k", zip, destination]
  }

  /// Checks the zip at `zip`, then unpacks it into the existing, empty folder at
  /// `destination` (both absolute paths in the staging folder) under the watchdog.
  public func extract(zip: String, into destination: String) async -> Result<
    Void, UpdateExtractionFailure
  > {
    if Task.isCancelled { return .failure(.cancelled) }
    if case .failure(let problem) = UpdateArchiveCheck.check(zipAtPath: zip, limits: limits) {
      return .failure(.archive(problem))
    }
    let folder = open(destination, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard folder >= 0 else { return .failure(.folderUnreadable(errno: errno)) }
    defer { Darwin.close(folder) }
    let request = ProcessRequest(
      executableURL: Self.dittoURL,
      arguments: Self.arguments(zip: zip, destination: destination),
      environment: ["PATH": ProcessEnvironment.systemSearchPath],
      timeout: Self.timeout,
      outputLimit: 64 * 1024)
    let (ran, exceeded) = await runWatched(request, folder: folder)
    if exceeded { return .failure(.expansionExceeded) }
    switch ran {
    case .cancelled: return .failure(.cancelled)
    case .notStarted: return .failure(.notStarted)
    case .finished(let result):
      if UpdateExpansionWatch.exceeds(root: folder, limits: limits) {
        return .failure(.expansionExceeded)
      }
      if result.timedOut { return .failure(.timedOut) }
      switch result.termination {
      case .exited(0): return .success(())
      case .exited(let status): return .failure(.exited(status))
      case .signaled(let signal): return .failure(.signaled(signal))
      }
    }
  } // End of func extract(zip:into:)

  /// How the runner's call ended.
  enum RunEnd: Sendable {
    /// The process ran to its end (or its time bound).
    case finished(ProcessResult)
    /// The run was cancelled: by the caller, or by the watchdog.
    case cancelled
    /// The process could not be started.
    case notStarted
  }

  /// What one of the watched run's two tasks reports.
  enum WatchEvent: Sendable {
    /// The runner's call ended.
    case ran(RunEnd)
    /// The watchdog found the destination past the bounds.
    case exceeded
    /// The watchdog stopped without finding that.
    case watchEnded
  }

  /// Runs `request` while a watchdog measures the open folder `folder` every
  /// `watchInterval`; when it passes the bounds the run is cancelled (the runner stops the
  /// process group and returns once it has ended). Returns how the run ended and whether the
  /// watchdog stopped it.
  func runWatched(_ request: ProcessRequest, folder: Int32) async -> (RunEnd, Bool) {
    let runner = runner
    let limits = limits
    let interval = watchInterval
    return await withTaskGroup(of: WatchEvent.self) { group in
      group.addTask {
        do {
          return .ran(.finished(try await runner.run(request)))
        } catch is CancellationError {
          return .ran(.cancelled)
        } catch {
          return .ran(Task.isCancelled ? .cancelled : .notStarted)
        }
      }
      group.addTask {
        while !Task.isCancelled {
          try? await Task.sleep(for: interval)
          if Task.isCancelled { break }
          if UpdateExpansionWatch.exceeds(root: folder, limits: limits) { return .exceeded }
        } // End of the watchdog's loop
        return .watchEnded
      }
      var ran = RunEnd.notStarted
      var exceeded = false
      while let event = await group.next() {
        switch event {
        case .ran(let end):
          ran = end
          group.cancelAll()
        case .exceeded:
          exceeded = true
          group.cancelAll()
        case .watchEnded:
          break
        }
      } // End of loop over the two tasks' events
      return (ran, exceeded)
    }
  } // End of func runWatched(_:folder:)
}

/// The extraction's watchdog measure (PLAN.md D39, I-13b1): a walk of what `ditto` has written
/// below the extraction folder that never follows a link and stops as soon as it passes the
/// bounds: more entries than `maximumEntries`, more bytes than `maximumBytes` (regular files'
/// and links' sizes plus the extended attribute values of files and folders, where the zip's
/// `._` entries end up), a level deeper than `maximumDepth`, or a folder that cannot be opened
/// (its contents could not be measured). An entry that vanishes while it is measured is
/// skipped (the next measure sees what replaced it).
enum UpdateExpansionWatch {
  /// Whether the tree below the open folder `root` passes `limits`.
  static func exceeds(root: Int32, limits: UpdateArchiveLimits) -> Bool {
    var tally = Tally(limits: limits)
    return !tally.walk(root, depth: 1)
  }

  /// The walk's state.
  struct Tally {
    /// The bounds.
    let limits: UpdateArchiveLimits
    /// Entries counted so far.
    var entries = 0
    /// Bytes counted so far.
    var bytes = 0

    /// Creates a tally within `limits`.
    init(limits: UpdateArchiveLimits) {
      self.limits = limits
    }

    /// Adds `count` bytes; whether the tally is still within the bound.
    mutating func add(bytes count: Int) -> Bool {
      bytes += max(count, 0)
      return bytes <= limits.maximumBytes
    }

    /// Walks the open folder `folder`, whose entries are at `depth` below the extraction
    /// folder; whether everything so far is within the bounds.
    mutating func walk(_ folder: Int32, depth: Int) -> Bool {
      guard depth <= limits.maximumDepth else { return false }
      let copy = dup(folder)
      guard copy >= 0, let stream = fdopendir(copy) else {
        if copy >= 0 { Darwin.close(copy) }
        return false
      }
      defer { closedir(stream) }
      rewinddir(stream)
      while let entry = readdir(stream) {
        var raw = entry.pointee.d_name
        let length = Int(entry.pointee.d_namlen)
        let name = withUnsafeBytes(of: &raw) { String(decoding: $0.prefix(length), as: UTF8.self) }
        if name == "." || name == ".." { continue }
        entries += 1
        guard entries <= limits.maximumEntries, visit(name, in: folder, depth: depth) else {
          return false
        }
      } // End of loop over the folder's entries
      return true
    } // End of func walk(_:depth:)

    /// Measures the entry `name` in the open folder `folder`, descending into a folder;
    /// whether everything so far is within the bounds.
    mutating func visit(_ name: String, in folder: Int32, depth: Int) -> Bool {
      var info = stat()
      guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT }
      switch info.st_mode & S_IFMT {
      case S_IFREG:
        guard add(bytes: Int(info.st_size)) else { return false }
        let file = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { return true }
        defer { Darwin.close(file) }
        return add(bytes: UpdateExpansionWatch.attributeBytes(file))
      case S_IFLNK:
        return add(bytes: Int(info.st_size))
      case S_IFDIR:
        let child = openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { return errno == ENOENT }
        defer { Darwin.close(child) }
        guard add(bytes: UpdateExpansionWatch.attributeBytes(child)) else { return false }
        return walk(child, depth: depth + 1)
      default:
        return true
      }
    } // End of func visit(_:in:depth:)
  }

  /// The total size of the extended attribute values of the open file or folder `descriptor`
  /// (0 when they cannot be listed).
  static func attributeBytes(_ descriptor: Int32) -> Int {
    let length = flistxattr(descriptor, nil, 0, 0)
    guard length > 0 else { return 0 }
    var names = [CChar](repeating: 0, count: length)
    let read = flistxattr(descriptor, &names, length, 0)
    guard read > 0 else { return 0 }
    var total = 0
    var start = 0
    for index in 0..<read where names[index] == 0 {
      let size = names.withUnsafeBufferPointer {
        fgetxattr(descriptor, $0.baseAddress! + start, nil, 0, 0, 0)
      }
      if size > 0 { total += size }
      start = index + 1
    } // End of loop over the attribute names
    return total
  } // End of static func attributeBytes(_:)
}

/// A folder's identity, its device and inode read without following a link (PLAN.md D39,
/// I-13b1). The shape check records the unpacked `muxFinder.app`'s; the verifier requires the
/// same identity at the bundle's path right before and after the code check and after the
/// versions are read, and the verified bundle carries it so I-13b2 can compare it again at
/// the swap.
public struct UpdateBundleIdentity: Sendable, Hashable {
  /// The device.
  public let device: Int64
  /// The inode.
  public let inode: UInt64

  /// The identity in `info`.
  init(_ info: stat) {
    device = Int64(info.st_dev)
    inode = UInt64(info.st_ino)
  }
}

/// What is wrong with the unpacked contents (PLAN.md D39, I-13b1).
public enum UpdateShapeProblem: Error, Sendable, Hashable {
  /// Nothing was unpacked.
  case noApp
  /// More than one top-level entry (two apps included).
  case extraEntries
  /// The one top-level entry is not named exactly `muxFinder.app`.
  case wrongName
  /// `muxFinder.app` is not a real folder (a file or a symbolic link).
  case appNotADirectory
  /// An entry is neither a regular file, a folder nor a symbolic link.
  case unsupportedEntry
  /// A symbolic link's target is absolute.
  case symbolicLinkAbsolute
  /// A symbolic link's target (lexically, `..` counted, never through another link) leads
  /// outside `muxFinder.app`, or is empty.
  case symbolicLinkEscapes
  /// More entries than the bound.
  case tooManyEntries
  /// More bytes in regular files than the bound.
  case tooLarge
  /// Folders nested deeper than the bound.
  case tooDeep
  /// An entry could not be read (this errno).
  case unreadable(errno: Int32)

  /// A stable, machine-readable name.
  public var code: String {
    switch self {
    case .noApp: return "noApp"
    case .extraEntries: return "extraEntries"
    case .wrongName: return "wrongName"
    case .appNotADirectory: return "appNotADirectory"
    case .unsupportedEntry: return "unsupportedEntry"
    case .symbolicLinkAbsolute: return "symbolicLinkAbsolute"
    case .symbolicLinkEscapes: return "symbolicLinkEscapes"
    case .tooManyEntries: return "tooManyEntries"
    case .tooLarge: return "tooLarge"
    case .tooDeep: return "tooDeep"
    case .unreadable(let code): return "unreadable.\(code)"
    }
  } // End of var code

  /// The reason, as a phrase after "Couldn't update: ".
  public var reason: String {
    switch self {
    case .noApp, .wrongName, .appNotADirectory: return "the download doesn't contain muxFinder.app"
    case .extraEntries: return "the download contains more than muxFinder.app"
    case .unsupportedEntry: return "the app in the download contains an unexpected kind of file"
    case .symbolicLinkAbsolute, .symbolicLinkEscapes:
      return "the app in the download has a link leading outside it"
    case .tooManyEntries, .tooLarge, .tooDeep: return "the app in the download is too large"
    case .unreadable: return "the app in the download can't be read"
    }
  } // End of var reason
}

/// The shape check of the unpacked contents (PLAN.md D39, I-13b1): exactly one top-level
/// entry, named `muxFinder.app`, a real folder (`lstat`); then a walk of the whole tree that
/// never follows a link, bounded in entries, bytes and depth, where every entry is a regular
/// file, a folder or a symbolic link, and no link's target is absolute or leads outside
/// `muxFinder.app`. A target is resolved lexically from the link's own folder (`.` skipped,
/// `..` going up, never above the app), and a `..` that would go back up out of a component
/// that is itself a symbolic link is refused, so a chain of links cannot climb out either.
public enum UpdateBundleShape {
  /// The app's name.
  public static let appName = "muxFinder.app"

  /// The walk's bounds.
  public struct Limits: Sendable, Hashable {
    /// The most entries below `muxFinder.app` (the 0.2.0 bundle has 14).
    public var maximumEntries: Int
    /// The most bytes in regular files (the 0.2.0 bundle has about 19.2 MB).
    public var maximumBytes: Int
    /// The deepest folder nesting below `muxFinder.app`.
    public var maximumDepth: Int

    /// Creates bounds.
    public init(maximumEntries: Int, maximumBytes: Int, maximumDepth: Int) {
      self.maximumEntries = maximumEntries
      self.maximumBytes = maximumBytes
      self.maximumDepth = maximumDepth
    }

    /// The bounds used: 10,000 entries, 256 MiB, 32 levels.
    public static let standard = Limits(
      maximumEntries: 10_000, maximumBytes: 256 << 20, maximumDepth: 32)
  }

  /// What the walk counted.
  public struct Summary: Sendable, Hashable {
    /// Entries below `muxFinder.app`.
    public var entries = 0
    /// Bytes in regular files.
    public var bytes = 0
    /// Symbolic links.
    public var symbolicLinks = 0
  }

  /// Checks the contents of the open folder `folder` (the fresh folder `ditto` unpacked
  /// into).
  public static func check(folder: Int32, limits: Limits = .standard) -> Result<
    Summary, UpdateShapeProblem
  > {
    switch openApp(in: folder) {
    case .failure(let problem):
      return .failure(problem)
    case .success(let app):
      defer { Darwin.close(app.descriptor) }
      return checkTree(app: app.descriptor, limits: limits)
    }
  } // End of static func check(folder:limits:)

  /// The open `muxFinder.app` folder and its identity.
  struct OpenedApp {
    /// The folder, open; the caller closes it.
    let descriptor: Int32
    /// Its device and inode, read with `lstat` and the same as the open folder's.
    let identity: UpdateBundleIdentity
  }

  /// The top-level check of the open folder `folder`: exactly one entry, named
  /// `muxFinder.app`, a real folder by `lstat`; opens it without following a link and checks
  /// that the open folder is the one `lstat` saw (its identity).
  static func openApp(in folder: Int32) -> Result<OpenedApp, UpdateShapeProblem> {
    let names: [String]
    do throws(PrivateStorageError) {
      names = try PrivateStorage.entryNames(in: folder)
    } catch {
      return .failure(.unreadable(errno: errnoValue(error)))
    }
    guard !names.isEmpty else { return .failure(.noApp) }
    guard names.count == 1 else { return .failure(.extraEntries) }
    guard names[0] == appName else { return .failure(.wrongName) }
    var info = stat()
    guard fstatat(folder, appName, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
      return .failure(.unreadable(errno: errno))
    }
    guard info.st_mode & S_IFMT == S_IFDIR else { return .failure(.appNotADirectory) }
    let app = openat(folder, appName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard app >= 0 else { return .failure(.unreadable(errno: errno)) }
    var opened = stat()
    guard fstat(app, &opened) == 0, UpdateBundleIdentity(opened) == UpdateBundleIdentity(info)
    else {
      Darwin.close(app)
      return .failure(.unreadable(errno: ESTALE))
    }
    return .success(OpenedApp(descriptor: app, identity: UpdateBundleIdentity(info)))
  } // End of static func openApp(in:)

  /// The walk of the open `muxFinder.app` folder `app` (see the type).
  static func checkTree(app: Int32, limits: Limits) -> Result<Summary, UpdateShapeProblem> {
    var walker = Walker(root: app, limits: limits)
    if let problem = walker.walk(app, components: []) { return .failure(problem) }
    return .success(walker.summary)
  }

  /// The errno inside a private storage error (`EIO` when there is none).
  static func errnoValue(_ error: PrivateStorageError) -> Int32 {
    if case .systemCallFailed(_, let code) = error { return code }
    return EIO
  }

  /// Why `target`, the target of a link in the folder `components` below the app's root
  /// `root`, is refused, or `nil` (see the type).
  static func linkProblem(target: String, components: [String], root: Int32) -> UpdateShapeProblem?
  {
    guard !target.isEmpty else { return .symbolicLinkEscapes }
    guard !target.hasPrefix("/") else { return .symbolicLinkAbsolute }
    var stack = components
    for part in target.split(separator: "/", omittingEmptySubsequences: true) {
      if part == "." { continue }
      if part == ".." {
        guard !stack.isEmpty else { return .symbolicLinkEscapes }
        if isSymbolicLink(stack.joined(separator: "/"), root: root) {
          return .symbolicLinkEscapes
        }
        stack.removeLast()
      } else {
        stack.append(String(part))
      }
    } // End of loop over the target's components
    return nil
  } // End of static func linkProblem(target:components:root:)

  /// Whether `relativePath` below `root` is a symbolic link; an entry that cannot be looked
  /// at for another reason than its absence counts as one (so the link is refused).
  static func isSymbolicLink(_ relativePath: String, root: Int32) -> Bool {
    var info = stat()
    guard fstatat(root, relativePath, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
      return !(errno == ENOENT || errno == ENOTDIR)
    }
    return info.st_mode & S_IFMT == S_IFLNK
  }

  /// The recursive walk's state.
  struct Walker {
    /// The app's open root folder.
    let root: Int32
    /// The bounds.
    let limits: Limits
    /// What was counted.
    var summary = Summary()

    /// Creates a walker over the app at `root`.
    init(root: Int32, limits: Limits) {
      self.root = root
      self.limits = limits
    }

    /// Walks the open folder `folder`, at `components` below the root; returns the first
    /// problem.
    mutating func walk(_ folder: Int32, components: [String]) -> UpdateShapeProblem? {
      guard components.count <= limits.maximumDepth else { return .tooDeep }
      let names: [String]
      do throws(PrivateStorageError) {
        names = try PrivateStorage.entryNames(in: folder)
      } catch {
        return .unreadable(errno: UpdateBundleShape.errnoValue(error))
      }
      for name in names.sorted() {
        summary.entries += 1
        guard summary.entries <= limits.maximumEntries else { return .tooManyEntries }
        if let problem = visit(name, in: folder, components: components) { return problem }
      } // End of loop over the folder's entries
      return nil
    } // End of func walk(_:components:)

    /// Checks the entry `name` in the open folder `folder`, descending into a folder.
    mutating func visit(_ name: String, in folder: Int32, components: [String])
      -> UpdateShapeProblem?
    {
      var info = stat()
      guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
        return .unreadable(errno: errno)
      }
      switch info.st_mode & S_IFMT {
      case S_IFREG:
        summary.bytes += Int(info.st_size)
        return summary.bytes > limits.maximumBytes ? .tooLarge : nil
      case S_IFLNK:
        summary.symbolicLinks += 1
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlinkat(folder, name, &buffer, Int(PATH_MAX))
        guard count >= 0 else { return .unreadable(errno: errno) }
        let target = String(
          decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return UpdateBundleShape.linkProblem(target: target, components: components, root: root)
      case S_IFDIR:
        let child = openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { return .unreadable(errno: errno) }
        defer { Darwin.close(child) }
        return walk(child, components: components + [name])
      default:
        return .unsupportedEntry
      }
    } // End of func visit(_:in:components:)
  }
}
