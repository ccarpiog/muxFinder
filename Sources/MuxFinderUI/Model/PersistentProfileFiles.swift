import Foundation
import MuxFinderCore

/// Why muxFinder's persistent profile file cannot be checked, installed or removed (PLAN.md
/// D26). Messages are English, sentence case, and never hold a path or a name of the user's.
public enum PersistentProfileProblem: Error, Sendable, Hashable {
  /// The helper's path cannot be given to iTerm2 (D2's rule), or the helper is missing.
  case helper(LaunchHelperPathError)
  /// The folder or the file was refused, the lock was busy, or a system call failed.
  case installer(PersistentProfileInstallerError)
  /// The document could not be made.
  case document(PersistentProfileError)

  /// The user-facing explanation.
  public var message: String {
    switch self {
    case .helper(.notAbsolute), .helper(.unsupportedCharacters):
      return "iTerm2 can't run muxFinder's helper from where muxFinder is installed, because its "
        + "path contains spaces or other special characters. Move muxFinder to /Applications "
        + "and try again."
    case .helper(let error):
      return error.message
    case .installer(let error):
      return error.message
    case .document(let error):
      return error.message
    }
  } // End of var message

  /// A short kind for the logs ("helper.unsupportedCharacters", "installer.busy"): never a
  /// path, a name or an errno's text.
  public var kind: String {
    switch self {
    case .helper(let error): return "helper." + Self.caseName(of: error)
    case .installer(let error): return "installer." + Self.caseName(of: error)
    case .document(let error): return "document." + Self.caseName(of: error)
    }
  }

  /// The name of an enum case without its values ("busy", "systemCallFailed").
  static func caseName(of value: Any) -> String {
    Mirror(reflecting: value).children.first?.label ?? String(describing: value)
  }
}

/// How `DynamicProfiles/muxFinder.json` compares with the profiles of a host list (PLAN.md
/// D26), from `PersistentProfileInstaller.status(for:)`.
public enum PersistentProfileStatus: Sendable, Hashable {
  /// No `muxFinder.json` is installed.
  case notInstalled
  /// muxFinder's file is installed and holds exactly the profiles of the host list.
  case current
  /// muxFinder's file is installed and differs from them (a host's profile was turned on or
  /// off, a host renamed, or the helper moved), or no host has a profile any more.
  case stale
  /// It cannot be checked or used, and why; `isInstalled` tells whether muxFinder's own file
  /// is there anyway (so "Remove profiles" is offered).
  case unavailable(PersistentProfileProblem, isInstalled: Bool)

  /// Whether muxFinder's own file is installed.
  public var isInstalled: Bool {
    switch self {
    case .notInstalled: return false
    case .current, .stale: return true
    case .unavailable(_, let isInstalled): return isInstalled
    }
  }

  /// A short kind for the logs: "notInstalled", "current", "stale", "unavailable.<problem>".
  public var kind: String {
    switch self {
    case .notInstalled: return "notInstalled"
    case .current: return "current"
    case .stale: return "stale"
    case .unavailable(let problem, _): return "unavailable." + problem.kind
    }
  }
}

/// What an install or a removal did.
public enum PersistentProfileChange: Sendable, Hashable {
  /// The file was written with this many profiles.
  case installed(count: Int)
  /// The file already held exactly those profiles; nothing was written.
  case unchanged
  /// The file was removed (by "Remove profiles", or by an install with no profile left).
  case removed
  /// There was no file to remove; nothing was done.
  case nothingToRemove
  /// An automatic update found no file installed, so none was created; nothing was done
  /// (`PersistentProfileManaging.update(_:)` only).
  case notInstalled
  /// Nothing was changed, and why.
  case failed(PersistentProfileProblem)

  /// Whether nothing was changed because of a problem.
  public var isFailure: Bool {
    if case .failed = self { return true }
    return false
  }

  /// A short kind for the logs.
  public var kind: String {
    switch self {
    case .installed: return "installed"
    case .unchanged: return "unchanged"
    case .removed: return "removed"
    case .nothingToRemove: return "nothingToRemove"
    case .notInstalled: return "notInstalled"
    case .failed(let problem): return "failed." + problem.kind
    }
  }
}

/// muxFinder's persistent profile file as Settings and the rewrite at launch use it (PLAN.md
/// D26). Every call works off the main actor; nothing contacts iTerm2. Production:
/// `PersistentProfileFiles` over the real `DynamicProfiles` folder; tests and previews use
/// fakes or nothing.
public protocol PersistentProfileManaging: Sendable {
  /// How the installed file compares with the profiles of `hosts`. Never writes.
  func status(for hosts: HostList) async -> PersistentProfileStatus
  /// Installs the profiles of `hosts` (none left removes the file), replacing only muxFinder's
  /// own file; with no file there, creates it ("Install profiles").
  func install(_ hosts: HostList) async -> PersistentProfileChange
  /// Updates muxFinder's own installed file to the profiles of `hosts` (none left removes it),
  /// never creating one: with no file there, nothing is written (`notInstalled`); the check
  /// and the write are one atomic operation, so a file removed meanwhile stays removed (the
  /// automatic updates at launch and after a save).
  func update(_ hosts: HostList) async -> PersistentProfileChange
  /// Removes muxFinder's own file, and nothing else.
  func remove() async -> PersistentProfileChange
}

/// The real persistent profile file: `PersistentProfileInstaller` with the helper next to the
/// running executable (`LaunchHelperPath.locate()`, which applies D2's path rule). Installs use
/// `replaceGenerated`, updates `updateExistingGenerated` (never creating the file) and removals
/// `onlyIfGenerated`, so a `muxFinder.json` muxFinder did not generate is never replaced or
/// removed. The blocking file work (and the installer's lock
/// wait, at most 5 s) runs on a global dispatch queue, never on the main actor or the
/// concurrency pool.
public struct PersistentProfileFiles: PersistentProfileManaging {
  /// The installer.
  public let installer: PersistentProfileInstaller
  /// Finds and validates the helper's path.
  public let helperPath: @Sendable () -> Result<LaunchHelperPath, LaunchHelperPathError>

  /// The real folders and the bundled helper.
  public init() {
    self.init(installer: PersistentProfileInstaller(), helperPath: Self.locateHelper)
  }

  /// `installer` with the helper `helperPath` finds (tests pass private folders and a fixed
  /// path).
  public init(
    installer: PersistentProfileInstaller,
    helperPath: @escaping @Sendable () -> Result<LaunchHelperPath, LaunchHelperPathError>
  ) {
    self.installer = installer
    self.helperPath = helperPath
  }

  /// The helper next to the running executable.
  @Sendable
  static func locateHelper() -> Result<LaunchHelperPath, LaunchHelperPathError> {
    do throws(LaunchHelperPathError) {
      return .success(try LaunchHelperPath.locate())
    } catch {
      return .failure(error)
    }
  }

  /// See `PersistentProfileManaging.status(for:)`. Without a usable helper the status is
  /// `unavailable`, still telling whether muxFinder's file is installed.
  public func status(for hosts: HostList) async -> PersistentProfileStatus {
    let installer = self.installer
    let helperPath = self.helperPath
    return await Self.offMainActor {
      let document: PersistentProfileDocument
      switch Self.document(for: hosts, helper: helperPath()) {
      case .failure(let problem):
        let installed = try? installer.installedContents()
        let isMuxFinders = installed.map(PersistentProfiles.isGenerated) ?? false
        return .unavailable(problem, isInstalled: isMuxFinders)
      case .success(let made):
        document = made
      }
      do throws(PersistentProfileInstallerError) {
        switch try installer.status(for: document) {
        case .notInstalled: return .notInstalled
        case .current: return .current
        case .stale: return .stale
        case .notMuxFinders:
          return .unavailable(.installer(.fileNotMuxFinders), isInstalled: false)
        }
      } catch {
        return .unavailable(.installer(error), isInstalled: false)
      }
    } // End of the work off the main actor
  } // End of func status(for:)

  /// See `PersistentProfileManaging.install(_:)`: `replaceGenerated`.
  public func install(_ hosts: HostList) async -> PersistentProfileChange {
    await write(hosts, replacing: .replaceGenerated)
  }

  /// See `PersistentProfileManaging.update(_:)`: `updateExistingGenerated`.
  public func update(_ hosts: HostList) async -> PersistentProfileChange {
    await write(hosts, replacing: .updateExistingGenerated)
  }

  /// Installs the document for `hosts` with `policy`, off the main actor.
  func write(
    _ hosts: HostList,
    replacing policy: PersistentProfileInstaller.ReplacePolicy
  ) async -> PersistentProfileChange {
    let installer = self.installer
    let helperPath = self.helperPath
    return await Self.offMainActor {
      let document: PersistentProfileDocument
      switch Self.document(for: hosts, helper: helperPath()) {
      case .failure(let problem): return .failed(problem)
      case .success(let made): document = made
      }
      do throws(PersistentProfileInstallerError) {
        switch try installer.install(document, replacing: policy) {
        case .written: return .installed(count: document.profiles.count)
        case .unchanged: return .unchanged
        case .removed: return .removed
        case .nothingToRemove: return .nothingToRemove
        case .notInstalled: return .notInstalled
        }
      } catch {
        return .failed(.installer(error))
      }
    } // End of the work off the main actor
  } // End of func write(_:replacing:)

  /// See `PersistentProfileManaging.remove()`. Needs no helper.
  public func remove() async -> PersistentProfileChange {
    let installer = self.installer
    return await Self.offMainActor {
      do throws(PersistentProfileInstallerError) {
        switch try installer.remove(onlyIfGenerated: true) {
        case .removed: return .removed
        case .notInstalled: return .nothingToRemove
        }
      } catch {
        return .failed(.installer(error))
      }
    }
  } // End of func remove()

  /// The document for `hosts` running `helper`, or why there is none.
  static func document(
    for hosts: HostList,
    helper: Result<LaunchHelperPath, LaunchHelperPathError>
  ) -> Result<PersistentProfileDocument, PersistentProfileProblem> {
    switch helper {
    case .failure(let error):
      return .failure(.helper(error))
    case .success(let helper):
      do throws(PersistentProfileError) {
        return .success(try PersistentProfiles.document(for: hosts, helper: helper))
      } catch {
        return .failure(.document(error))
      }
    }
  } // End of func document(for:helper:)

  /// Runs blocking `work` on a global dispatch queue and returns its result.
  static func offMainActor<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: work())
      }
    }
  }
}
