import Foundation

/// Why the running copy cannot replace itself (PLAN.md D39, I-13b2). I-13c shows `reason`
/// next to "Download" (which opens the release page) in place of Update: a short lowercase
/// phrase with no path, host or Team ID.
public enum UpdateIneligibility: Error, Sendable, Hashable {
  /// The running app is not signed with a Developer ID Application certificate (a development
  /// build, an ad hoc signature or none at all).
  case notDeveloperID
  /// The running app's signature could not be read, or it carries no usable Team ID.
  case signatureUnreadable
  /// macOS runs the app from App Translocation (a path component `AppTranslocation`).
  case translocated
  /// The running app is not in a usable app bundle folder.
  case bundleUnusable(UpdateInstalledBundleProblem)
  /// The app is on a read-only volume (`MNT_RDONLY`, such as a disk image).
  case readOnlyVolume
  /// Another user owns the app's folder.
  case notOwnedByUser
  /// The user cannot write the app's folder or the folder it is in.
  case notWritable
  /// The running app's `CFBundleVersion` cannot be parsed, so no build is newer.
  case runningBuildUnknown
  /// The update folder (`~/Library/Application Support/muxFinder/update/`) cannot be used.
  case stagingRootUnusable(UpdateStagingProblem)
  /// The update folder is on another volume than the app, so the swap cannot be a rename.
  case differentVolume

  /// A stable, machine-readable name.
  public var code: String {
    switch self {
    case .notDeveloperID: return "notDeveloperID"
    case .signatureUnreadable: return "signatureUnreadable"
    case .translocated: return "translocated"
    case .bundleUnusable(let problem): return "bundleUnusable.\(problem.code)"
    case .readOnlyVolume: return "readOnlyVolume"
    case .notOwnedByUser: return "notOwnedByUser"
    case .notWritable: return "notWritable"
    case .runningBuildUnknown: return "runningBuildUnknown"
    case .stagingRootUnusable(let problem): return "stagingRootUnusable.\(problem.code)"
    case .differentVolume: return "differentVolume"
    }
  } // End of var code

  /// The reason, as a phrase shown next to "Download".
  public var reason: String {
    switch self {
    case .notDeveloperID: return "this copy isn't signed with a Developer ID"
    case .signatureUnreadable: return "this copy's signature can't be read"
    case .translocated: return "macOS runs this copy from a temporary location"
    case .bundleUnusable: return "this copy isn't in a usable app folder"
    case .readOnlyVolume: return "this copy is on a read-only disk"
    case .notOwnedByUser: return "this copy belongs to another user"
    case .notWritable: return "you can't change the folder this copy is in"
    case .runningBuildUnknown: return "this copy's build number can't be read"
    case .stagingRootUnusable: return "muxFinder's update folder can't be used"
    case .differentVolume: return "this copy is on another disk than muxFinder's update folder"
    }
  } // End of var reason
}

/// What is wrong with the running app's bundle folder (PLAN.md D39, I-13b2).
public enum UpdateInstalledBundleProblem: Error, Sendable, Hashable {
  /// The path is not absolute, or has an empty, `.` or `..` component.
  case notAPlainAbsolutePath
  /// A component of the path does not exist.
  case missing
  /// A component of the path is a symbolic link.
  case symbolicLinkOnPath
  /// The bundle (or a folder on its path) is not a folder.
  case notAFolder
  /// `Contents/Info.plist` cannot be read as a property list dictionary.
  case infoUnreadable
  /// `CFBundleIdentifier` is not `cc.carpio.muxfinder`.
  case identifierMismatch
  /// The running executable is not the bundle's main executable.
  case executableOutside
  /// The bundle is a mount point (its device differs from its parent folder's).
  case mountPoint
  /// A system call failed with this errno.
  case unreadable(errno: Int32)

  /// A stable, machine-readable name.
  public var code: String {
    switch self {
    case .notAPlainAbsolutePath: return "notAPlainAbsolutePath"
    case .missing: return "missing"
    case .symbolicLinkOnPath: return "symbolicLinkOnPath"
    case .notAFolder: return "notAFolder"
    case .infoUnreadable: return "infoUnreadable"
    case .identifierMismatch: return "identifierMismatch"
    case .executableOutside: return "executableOutside"
    case .mountPoint: return "mountPoint"
    case .unreadable(let code): return "unreadable.\(code)"
    }
  } // End of var code
}

/// What the running app's own signature says (PLAN.md D39, I-13b2), read by
/// `UpdateSigningReader`.
public enum UpdateSigningReading: Sendable, Hashable {
  /// The signature was read: whether it satisfies the Developer ID requirement, and its Team
  /// ID when it has one that is a well-formed `UpdateTeamID`.
  case read(isDeveloperID: Bool, team: UpdateTeamID?)
  /// The signature could not be read (this `OSStatus`).
  case unreadable(status: Int32)
}

/// The facts about the running app's bundle folder (PLAN.md D39, I-13b2), read by
/// `UpdateInstalledBundleReader`.
public struct UpdateInstalledBundleFacts: Sendable, Hashable {
  /// The bundle's absolute path.
  public var path: String
  /// Why the bundle cannot be used, if it cannot.
  public var problem: UpdateInstalledBundleProblem?
  /// The bundle folder's identity (device and inode), when it was read.
  public var identity: UpdateBundleIdentity?
  /// Whether a component of the path (or of the running executable's) is `AppTranslocation`.
  public var isTranslocated: Bool
  /// Whether the bundle's volume is mounted read-only.
  public var isReadOnlyVolume: Bool
  /// Whether the user owns the bundle folder.
  public var isOwnedByUser: Bool
  /// Whether the user can write the bundle folder.
  public var isBundleWritable: Bool
  /// Whether the user can write the folder the bundle is in.
  public var isParentWritable: Bool
  /// `CFBundleShortVersionString`, when read.
  public var shortVersion: String?
  /// `CFBundleVersion`, when read.
  public var build: String?

  /// Facts with these values; the defaults describe a bundle nothing was read of.
  public init(
    path: String,
    problem: UpdateInstalledBundleProblem? = nil,
    identity: UpdateBundleIdentity? = nil,
    isTranslocated: Bool = false,
    isReadOnlyVolume: Bool = false,
    isOwnedByUser: Bool = false,
    isBundleWritable: Bool = false,
    isParentWritable: Bool = false,
    shortVersion: String? = nil,
    build: String? = nil
  ) {
    self.path = path
    self.problem = problem
    self.identity = identity
    self.isTranslocated = isTranslocated
    self.isReadOnlyVolume = isReadOnlyVolume
    self.isOwnedByUser = isOwnedByUser
    self.isBundleWritable = isBundleWritable
    self.isParentWritable = isParentWritable
    self.shortVersion = shortVersion
    self.build = build
  } // End of init(path:problem:identity:isTranslocated:isReadOnlyVolume:…)
}

/// What a read-only look at the update folder found (PLAN.md D39, I-13b2). Nothing is created.
public enum UpdateStagingRootState: Sendable, Hashable {
  /// The folder exists and passes the checks; it is on `device`.
  case usable(device: Int64)
  /// The folder does not exist yet (an update creates it); the nearest folder above it that
  /// exists, with no symbolic link on the way, is on `device`.
  case missing(device: Int64)
  /// The folder, or a folder on its path, cannot be used.
  case unusable(UpdateStagingProblem)

  /// The device the folder is (or will be) on, when it can be used.
  public var device: Int64? {
    switch self {
    case .usable(let device), .missing(let device): return device
    case .unusable: return nil
    }
  }
}

/// Everything eligibility is decided from (PLAN.md D39, I-13b2).
public struct UpdateEligibilityFacts: Sendable, Hashable {
  /// The running app's signature.
  public var signing: UpdateSigningReading
  /// The running app's bundle folder.
  public var bundle: UpdateInstalledBundleFacts
  /// The update folder.
  public var stagingRoot: UpdateStagingRootState

  /// Facts of these values.
  public init(
    signing: UpdateSigningReading, bundle: UpdateInstalledBundleFacts,
    stagingRoot: UpdateStagingRootState
  ) {
    self.signing = signing
    self.bundle = bundle
    self.stagingRoot = stagingRoot
  }
}

/// What an eligible copy records for the update (PLAN.md D39, I-13b2): the team the download
/// must be signed by, the installed bundle and its identity (compared again right before the
/// swap), and the running build the download must be newer than.
public struct UpdateEligibleInstall: Sendable, Hashable {
  /// The running app's Team ID.
  public let team: UpdateTeamID
  /// The installed bundle's absolute path (no symbolic link on it).
  public let bundlePath: String
  /// The installed bundle folder's identity.
  public let identity: UpdateBundleIdentity
  /// The running `CFBundleVersion` (parsed by `UpdateBundleVersions.build`).
  public let runningBuild: String
  /// The running `CFBundleShortVersionString`, when it is a version of ours.
  public let runningVersion: UpdateVersion?

  /// An install of these values.
  public init(
    team: UpdateTeamID, bundlePath: String, identity: UpdateBundleIdentity, runningBuild: String,
    runningVersion: UpdateVersion?
  ) {
    self.team = team
    self.bundlePath = bundlePath
    self.identity = identity
    self.runningBuild = runningBuild
    self.runningVersion = runningVersion
  }
}

/// Whether the running copy can update itself in place (PLAN.md D39, I-13b2): a pure decision
/// over `UpdateEligibilityFacts`, which `UpdateEligibilityReader` gathers read-only. Nothing
/// here creates or writes anything.
public enum UpdateEligibility: Sendable, Hashable {
  /// The copy can update itself.
  case eligible(UpdateEligibleInstall)
  /// It cannot, for this reason.
  case notEligible(UpdateIneligibility)

  /// Decides from `facts`, the first reason in this order: the signature (unreadable, not a
  /// Developer ID, no Team ID), App Translocation, the bundle folder, a read-only volume, the
  /// folder's owner, write access to the folder and its parent, the running build, the update
  /// folder, and last whether the update folder, the bundle and its parent share one device.
  public static func decide(_ facts: UpdateEligibilityFacts) -> UpdateEligibility {
    let team: UpdateTeamID
    switch facts.signing {
    case .unreadable: return .notEligible(.signatureUnreadable)
    case .read(isDeveloperID: false, _): return .notEligible(.notDeveloperID)
    case .read(isDeveloperID: true, team: nil): return .notEligible(.signatureUnreadable)
    case .read(isDeveloperID: true, team: let read?): team = read
    }
    let bundle = facts.bundle
    if bundle.isTranslocated { return .notEligible(.translocated) }
    if let problem = bundle.problem { return .notEligible(.bundleUnusable(problem)) }
    guard let identity = bundle.identity else {
      return .notEligible(.bundleUnusable(.unreadable(errno: EIO)))
    }
    if bundle.isReadOnlyVolume { return .notEligible(.readOnlyVolume) }
    if !bundle.isOwnedByUser { return .notEligible(.notOwnedByUser) }
    if !bundle.isBundleWritable || !bundle.isParentWritable { return .notEligible(.notWritable) }
    guard let build = bundle.build, UpdateBundleVersions.build(build) != nil else {
      return .notEligible(.runningBuildUnknown)
    }
    switch facts.stagingRoot {
    case .unusable(let problem): return .notEligible(.stagingRootUnusable(problem))
    case .usable(let device), .missing(let device):
      guard device == identity.device else { return .notEligible(.differentVolume) }
    }
    return .eligible(
      UpdateEligibleInstall(
        team: team, bundlePath: bundle.path, identity: identity, runningBuild: build,
        runningVersion: bundle.shortVersion.flatMap { UpdateVersion($0) }))
  } // End of static func decide(_:)
}

/// The lines `--report-update-eligibility` prints (PLAN.md D39, I-13b2): the verdict, then
/// the facts behind it, each `muxFinder update eligibility: …`. Never a path or the Team ID's
/// value.
public enum UpdateEligibilityReport {
  /// Every line's prefix.
  public static let prefix = "muxFinder update eligibility: "

  /// The lines for `facts` and the decision taken from them.
  public static func lines(_ facts: UpdateEligibilityFacts) -> [String] {
    let decision = UpdateEligibility.decide(facts)
    let bundle = facts.bundle
    var lines: [String] = []
    switch decision {
    case .eligible: lines.append("eligible")
    case .notEligible(let reason):
      lines.append("not eligible (\(reason.code): \(reason.reason))")
    }
    switch facts.signing {
    case .unreadable(let status):
      lines.append("Developer ID: unknown (signature unreadable, status \(status))")
      lines.append("Team ID: unknown")
    case .read(let isDeveloperID, let team):
      lines.append("Developer ID: \(yes(isDeveloperID))")
      lines.append("Team ID: \(team == nil ? "absent" : "present")")
    }
    lines.append("translocated: \(yes(bundle.isTranslocated))")
    lines.append("app folder: \(bundle.problem.map { "unusable (\($0.code))" } ?? "usable")")
    lines.append("read-only volume: \(yes(bundle.isReadOnlyVolume))")
    lines.append(
      "writable: \(yes(bundle.isBundleWritable && bundle.isParentWritable && bundle.isOwnedByUser))"
        + " (app folder \(yes(bundle.isBundleWritable)), enclosing folder "
        + "\(yes(bundle.isParentWritable)), owned by you \(yes(bundle.isOwnedByUser)))")
    lines.append("update folder: \(rootDescription(facts.stagingRoot))")
    lines.append("same volume: \(sameVolume(facts))")
    lines.append(
      "running version \(bundle.shortVersion ?? "unknown") build \(bundle.build ?? "unknown")")
    return lines.map { prefix + $0 }
  } // End of static func lines(_:)

  /// `yes` or `no`.
  static func yes(_ value: Bool) -> String { value ? "yes" : "no" }

  /// The update folder's state in words.
  static func rootDescription(_ state: UpdateStagingRootState) -> String {
    switch state {
    case .usable: return "present"
    case .missing: return "not created yet (an update creates it)"
    case .unusable(let problem): return "unusable (\(problem.code))"
    }
  }

  /// Whether the update folder and the app share one device: `yes`, `no` or `unknown`.
  static func sameVolume(_ facts: UpdateEligibilityFacts) -> String {
    guard let root = facts.stagingRoot.device, let app = facts.bundle.identity?.device else {
      return "unknown"
    }
    return yes(root == app)
  }
}
