import Foundation

/// The removal of muxFinder's dynamic profile file for `scripts/uninstall.sh` (PLAN.md D26,
/// D27): the app binary's `--remove-persistent-profiles` mode runs it, so whether
/// `DynamicProfiles/muxFinder.json` is muxFinder's generated file is decided by the same code
/// as the app's "Remove profiles" (`PersistentProfileInstaller.remove(onlyIfGenerated:)`, under
/// the lock in muxFinder's own folder), never by a check written in shell.
///
/// - **Removal:** only a generated document (`PersistentProfiles.isGenerated(_:)`) is deleted;
///   any other `muxFinder.json` (the user's own file, a link, a folder, another user's file) is
///   left exactly as it is, and no other entry of the folder is read or changed.
/// - **Dry run:** reads the file without the lock and without creating anything (no
///   `DynamicProfiles` folder, no lock folder or file) and reports what a removal would do.
/// - **Report:** one English line naming the file (`report(_:)`; the script prints it as it is),
///   and an exit status for the script:
///   `exitSuccess` (removed, nothing installed, or a dry run that would remove it),
///   `exitLeftAsItIs` (not muxFinder's file, left alone on purpose), `exitFailed` (the removal
///   failed, the file left or put back). `exitUsage` is the app's status for unusable
///   arguments (`AppLaunchOptions.usageError`).
public struct PersistentProfileRemoval: Sendable {
  /// What the removal did, or in a dry run would do.
  public enum Outcome: Sendable, Hashable {
    /// `muxFinder.json` was muxFinder's generated file and was deleted.
    case removed
    /// Dry run: `muxFinder.json` is muxFinder's generated file; a removal would delete it.
    case wouldRemove
    /// There is no `muxFinder.json` (or no `DynamicProfiles` folder); nothing was done.
    case notInstalled
    /// `muxFinder.json` is not a file muxFinder generated or may touch (`reason` says why); it
    /// was left exactly as it is.
    case leftAsItIs(reason: PersistentProfileInstallerError)
    /// The removal failed (`reason` says why); the file was left as it is, or put back.
    case failed(reason: PersistentProfileInstallerError)
  }

  /// Exit status: removed, nothing installed, or a dry run that found muxFinder's file.
  public static let exitSuccess: Int32 = 0
  /// Exit status: the file is not muxFinder's and was left as it is.
  public static let exitLeftAsItIs: Int32 = 1
  /// Exit status: unusable arguments (the app prints the usage; nothing was looked at).
  public static let exitUsage: Int32 = 2
  /// Exit status: the removal failed; the file was left as it is or put back.
  public static let exitFailed: Int32 = 3

  /// The installer whose folder holds the file.
  public let installer: PersistentProfileInstaller
  /// Whether only to report what a removal would do.
  public let dryRun: Bool

  /// A removal through `installer`.
  public init(installer: PersistentProfileInstaller, dryRun: Bool) {
    self.installer = installer
    self.dryRun = dryRun
  }

  /// A removal from the command line's folders: `profilesDirectory` standing in for iTerm2's
  /// `DynamicProfiles` and `lockDirectory` for muxFinder's own folder (checks only; the caller
  /// passes both or neither, absolute), else the real folders (`PersistentProfileInstaller()`).
  public init(profilesDirectory: String?, lockDirectory: String?, dryRun: Bool) {
    if let profilesDirectory, let lockDirectory {
      self.init(
        installer: PersistentProfileInstaller(
          directory: URL(fileURLWithPath: profilesDirectory, isDirectory: true),
          lockDirectory: URL(fileURLWithPath: lockDirectory, isDirectory: true)),
        dryRun: dryRun)
    } else {
      self.init(installer: PersistentProfileInstaller(), dryRun: dryRun)
    }
  } // End of init(profilesDirectory:lockDirectory:dryRun:)

  /// Removes the file when it is muxFinder's generated file (under the lock), or in a dry run
  /// only looks at it.
  public func run() -> Outcome {
    do throws(PersistentProfileInstallerError) {
      if dryRun {
        guard let data = try installer.installedContents() else { return .notInstalled }
        return PersistentProfiles.isGenerated(data)
          ? .wouldRemove : .leftAsItIs(reason: .fileNotMuxFinders)
      }
      switch try installer.remove(onlyIfGenerated: true) {
      case .removed: return .removed
      case .notInstalled: return .notInstalled
      }
    } catch {
      return Self.outcome(for: error)
    }
  } // End of func run()

  /// Sorts a refusal into "not muxFinder's, left alone" and "failed": a file or folder muxFinder
  /// never writes (not a generated document, a link, not a regular file or folder, another
  /// user's, too large) is left as it is; anything else (the lock, a system call, a file that
  /// changed meanwhile) is a failure.
  static func outcome(for error: PersistentProfileInstallerError) -> Outcome {
    switch error {
    case .fileNotMuxFinders, .fileIsSymbolicLink, .fileNotRegular, .fileNotOwnedByUser,
      .fileTooLarge, .directoryIsSymbolicLink, .directoryNotADirectory, .directoryNotOwnedByUser:
      return .leftAsItIs(reason: error)
    case .directoryMissing, .fileAlreadyExists, .fileChanged, .displacedEntryKept, .busy,
      .lockUnavailable, .systemCallFailed:
      return .failed(reason: error)
    }
  } // End of static func outcome(for:)

  /// The exit status for `outcome`.
  public static func exitStatus(for outcome: Outcome) -> Int32 {
    switch outcome {
    case .removed, .wouldRemove, .notInstalled: return exitSuccess
    case .leftAsItIs: return exitLeftAsItIs
    case .failed: return exitFailed
    }
  }

  /// The one line printed for `outcome`, naming the file (English, sentence case after the
  /// prefix).
  public func report(_ outcome: Outcome) -> String {
    let path = installer.fileURL.path(percentEncoded: false)
    let prefix = "muxFinder persistent profiles: "
    switch outcome {
    case .removed:
      return prefix + "removed \(path)"
    case .wouldRemove:
      return prefix + "would remove \(path) (muxFinder's generated file)"
    case .notInstalled:
      return prefix + "none installed at \(path)"
    case .leftAsItIs(let reason):
      return prefix + "left \(path) as it is (\(Self.leftReason(reason)))"
    case .failed(let reason):
      return prefix + "could not remove \(path): \(reason.message)"
    }
  } // End of func report(_:)

  /// Why a file was left as it is, as a short phrase for `report(_:)`.
  static func leftReason(_ reason: PersistentProfileInstallerError) -> String {
    switch reason {
    case .fileNotMuxFinders: return "not muxFinder's generated file"
    case .fileIsSymbolicLink: return "a symbolic link"
    case .fileNotRegular: return "not a regular file"
    case .fileNotOwnedByUser: return "another user's file"
    case .fileTooLarge: return "too large to be muxFinder's file"
    case .directoryIsSymbolicLink: return "iTerm2's DynamicProfiles folder is a symbolic link"
    case .directoryNotADirectory: return "iTerm2's DynamicProfiles path is not a folder"
    case .directoryNotOwnedByUser: return "iTerm2's DynamicProfiles folder is another user's"
    default: return reason.message
    }
  } // End of static func leftReason(_:)
}
